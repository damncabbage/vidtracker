module Main where

import Prelude

import Control.Monad.Aff (Aff, attempt, launchAff)
import Control.Monad.Aff.AVar (AVAR)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Aff.Console (error)
import Control.Monad.Eff (Eff, kind Effect)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (CONSOLE, log)
import Control.Monad.Except (runExcept)
import Data.Array (filter, sortBy)
import Data.Either (Either(Left, Right))
import Data.Foreign (Foreign)
import Data.Function.Uncurried (Fn3)
import Data.Maybe (Maybe(..))
import Data.Newtype (unwrap)
import Data.String (Pattern(Pattern), contains)
import Data.Symbol (class IsSymbol, SProxy(..), reflectSymbol)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(Tuple), fst, snd)
import Node.Buffer (BUFFER, Buffer, create, writeString)
import Node.ChildProcess (CHILD_PROCESS, defaultExecOptions, defaultSpawnOptions, exec, spawn)
import Node.Encoding (Encoding(..))
import Node.Express.App (App, AppM, listenHttp, use, useExternal)
import Node.Express.App as E
import Node.Express.Handler (HandlerM(HandlerM))
import Node.Express.Middleware.Static (static)
import Node.Express.Response (sendJson, setStatus)
import Node.Express.Types (ExpressM, Request, Response)
import Node.FS (FS)
import Node.FS.Aff (mkdir, readdir, rename, stat)
import Node.FS.Stats (modifiedTime)
import Node.HTTP (HTTP)
import Node.Path (concat)
import Node.Platform (Platform(..))
import Node.Process (PROCESS, lookupEnv, platform)
import Routes (GetRoute, PostRoute, files, getIcons, open, remove, update, watched)
import SQLite3 (DBConnection, DBEffects, FilePath, newDB, queryDB)
import Simple.JSON (class ReadForeign, class WriteForeign, read, write)
import Types (FileData(FileData), GetIconsRequest, OpenRequest(OpenRequest), Path(Path), RemoveRequest(RemoveRequest), Success(Success), WatchedData)
import Unsafe.Coerce (unsafeCoerce)

readdir' :: forall eff.
  String
  -> Aff
       ( fs :: FS
       | eff
       )
       (Array Path)
readdir' path = do
  withStats <- traverse pairWithStat =<< filter (contains (Pattern "mkv"))
                                     <$> readdir path
  pure $ Path <<< fst <$> sortByDate withStats
  where
    pairWithStat file = do
      s <- stat $ concat [path, file]
      pure (Tuple file s)
    sortByDate = sortBy <<< flip $ comparing (modifiedTime <<< snd)

getBuffer :: forall e.
  Int
  -> String
  -> Eff
    ( buffer :: BUFFER
    | e
    )
    Buffer
getBuffer size json = do
  buffer <- create size
  _ <- writeString UTF8 0 size json buffer
  pure buffer

type Config =
  { db :: DBConnection
  , dir :: String
  }

type AppEffects eff =
  ( avar :: AVAR
  , console :: CONSOLE
  , db :: DBEffects
  , process :: PROCESS
  , cp :: CHILD_PROCESS
  , http :: HTTP
  , fs :: FS
  , buffer :: BUFFER
  | eff
  )

class GetFiles m where
  getFiles :: Config -> m (Array Path)

instance gfAF ::
  ( MonadAff (fs :: FS | trash) (Aff e)
  ) => GetFiles (Aff e) where
  getFiles {dir} = liftAff $ readdir' dir

class GetWatched m where
  getWatchedData :: Config -> m (Array WatchedData)

instance gwA ::
  ( MonadAff (db :: DBEffects | trash) (Aff e)
  ) => GetWatched (Aff e) where
  getWatchedData {db} = do
    watchedData :: Array WatchedData <- liftAff $ unsafeCoerce <$>
      queryDB db "SELECT path, created FROM watched;" []
    pure $ watchedData

class GetIcons m where
  getIconsData :: Config -> GetIconsRequest -> m Success

instance giA ::
  ( MonadAff (cp :: CHILD_PROCESS | trash) (Aff e)
  ) => GetIcons (Aff e) where
  getIconsData {db} _ = do
    _ <- liftAff <<< liftEff $ spawn "node" ["get-icons.js"] defaultSpawnOptions
    pure $ Success {status: "ok"}

class UpdateWatched m where
  updateWatched :: Config -> FileData -> m (Array WatchedData)

instance uwA ::
  ( MonadAff (db :: DBEffects | trash) (Aff e)
  ) => UpdateWatched (Aff e) where
  updateWatched config@{db} (FileData ur) = do
    _ <- liftAff $ if ur.watched
      then queryDB db "INSERT OR REPLACE INTO watched (path, created) VALUES ($1, datetime());" [unwrap ur.path]
      else queryDB db "DELETE FROM watched WHERE path = $1" [unwrap ur.path]
    getWatchedData config

class OpenFile m where
  openFile :: Config -> OpenRequest -> m (Success)

instance ofA ::
  ( MonadAff (cp :: CHILD_PROCESS | trash) (Aff e)
  ) => OpenFile (Aff e) where
  openFile {dir} (OpenRequest or) = do
    _ <- liftAff $ case platform of
          Just Darwin -> liftEff $ void $ spawn "open" (pure $ concat [dir, unwrap or.path]) defaultSpawnOptions
          _ -> liftEff $ exec ("start \"\" \"rust-vlc-finder\" \"" <> concat [dir, unwrap or.path] <>  "\"") defaultExecOptions (const $ pure unit)
    pure $ Success {status: "ok"}

class RemoveFile m where
  removeFile :: Config -> RemoveRequest -> m (Success)

instance rfA ::
  ( MonadAff (fs :: FS | trash) (Aff e)
  ) => RemoveFile (Aff e) where
  removeFile {dir} (RemoveRequest rr) = do
    let archive = concat [dir, "archive"]
    let name = unwrap rr.path
    let old = concat [dir, name]
    let new = concat [archive, name]
    _ <- liftAff $ do
      void $ attempt $ mkdir archive
      void $ attempt $ rename old new
    pure $ Success {status: "ok"}

ensureDB :: forall eff. FilePath -> Aff (db :: DBEffects | eff) DBConnection
ensureDB path = do
  db <- newDB path
  _ <- queryDB db "CREATE TABLE IF NOT EXISTS watched (path varchar(20) primary key unique, created datetime);" []
  pure db

foreign import jsonBodyParser :: forall e. Fn3 Request Response (ExpressM e Unit) (ExpressM e Unit)

foreign import _getBody :: Request -> Foreign

getBody :: forall e. HandlerM e Foreign
getBody = HandlerM \req _ _ -> pure $ _getBody req

handleGet :: forall res url
    . IsSymbol url
  => WriteForeign res
  => Config
  -> GetRoute res url
  -> (Config -> Aff _ res)
  -> AppM _ Unit
handleGet config route action =
  E.get route handler'
  where
    route = reflectSymbol (SProxy :: SProxy url)
    handler' = do
      response <- liftAff $ action config
      sendJson $ write response

handlePost :: forall req res url
    . IsSymbol url
  => WriteForeign res
  => ReadForeign req
  => Config
  -> PostRoute req res url
  -> (Config -> req -> Aff _ res)
  -> AppM _ Unit
handlePost config route action =
  E.post route handler'
  where
    route = reflectSymbol (SProxy :: SProxy url)
    handler' = do
      body <- getBody
      case runExcept (read body) of
        Right (r :: req) -> do
          response <- liftAff $ action config r
          sendJson $ write response
        Left e -> do
          setStatus 400
          sendJson $ write {error: show e}

routes :: Config -> App _
routes config = do
  useExternal jsonBodyParser
  get files getFiles
  get watched getWatchedData
  post getIcons getIconsData
  post update updateWatched
  post open openFile
  post remove removeFile
  use $ static "dist"
  where
    get :: forall res url
       . IsSymbol url
      => WriteForeign res
      => GetRoute res url
      -> (Config -> Aff _ res)
      -> AppM _ Unit
    get = handleGet config

    post :: forall req res url
       . IsSymbol url
      => WriteForeign res
      => ReadForeign req
      => PostRoute req res url
      -> (Config -> req -> Aff _ res)
      -> AppM _ Unit
    post = handlePost config

main :: Eff _ Unit
main = void $ launchAff do
  dir' <- liftEff $ lookupEnv "FILETRACKER_DIR"
  case dir' of
    Nothing -> error "we done broke now!!!!"
    Just dir -> do
      db <- ensureDB $ concat [dir, "filetracker"]
      void $ liftEff $ listenHttp (routes {db, dir}) 3000 \_ ->
        log "Started server"
