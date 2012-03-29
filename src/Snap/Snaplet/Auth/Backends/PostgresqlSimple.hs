{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

{-|

This module allows you to use the auth snaplet with your user database stored
in a PostgreSQL database.  When you run your application with this snaplet, a
config file will be copied into the the snaplets/postgresql-auth directory.
This file contains all of the configurable options for the snaplet and allows
you to change them without recompiling your application.  

To use this snaplet in your application enable the session, postgres, and auth
snaplets as follows:

> data App = App
>     { ... -- your own application state here
>     , _sess :: Snaplet SessionManager
>     , _db   :: Snaplet Postgres
>     , _auth :: Snaplet (AuthManager App)
>     }

Then in your initializer you'll have something like this:

> d <- nestSnaplet "db" db pgsInit
> a <- nestSnaplet "auth" auth $ initPostgresAuth sess d

If you have not already created the database table for users, it will
automatically be created for you the first time you run your application.

-}

module Snap.Snaplet.Auth.Backends.PostgresqlSimple
  ( initPostgresAuth
  ) where

------------------------------------------------------------------------------
import           Control.Arrow
import qualified Data.Configurator as C
import qualified Data.HashMap.Lazy as HM
import qualified Data.Text as T
import           Data.Text (Text)
import qualified Data.Text.Encoding as T
import           Data.Maybe
import           Data.Pool
import qualified Database.PostgreSQL.Simple as P
import qualified Database.PostgreSQL.Simple.Param as P
import           Database.PostgreSQL.Simple.Result
import           Database.PostgreSQL.Simple.QueryResults
import           Database.PostgreSQL.Simple.Types
import           Snap
import           Snap.Snaplet.Auth
import           Snap.Snaplet.PostgresqlSimple
import           Snap.Snaplet.Session
import           Snap.Snaplet.Session.Common
import           Web.ClientSession
import           Paths_snaplet_postgresql_simple


data PostgresAuthManager = PostgresAuthManager
    { pamTable    :: AuthTable
    , pamConnPool :: Pool P.Connection
    }


------------------------------------------------------------------------------
-- | Simple function to get auth settings from a config file.  All options
-- are optional and default to what's in defAuthSettings if not supplied.
settingsFromConfig :: Initializer b (AuthManager b) AuthSettings
settingsFromConfig = do
    config <- getSnapletUserConfig
    minPasswordLen <- liftIO $ C.lookup config "minPasswordLen"
    let pw = maybe id (\x s -> s { asMinPasswdLen = x }) minPasswordLen
    rememberCookie <- liftIO $ C.lookup config "rememberCookie"
    let rc = maybe id (\x s -> s { asRememberCookieName = x }) rememberCookie
    rememberPeriod <- liftIO $ C.lookup config "rememberPeriod"
    let rp = maybe id (\x s -> s { asRememberPeriod = Just x }) rememberPeriod
    lockout <- liftIO $ C.lookup config "lockout"
    let lo = maybe id (\x s -> s { asLockout = Just (second fromInteger x) })
                   lockout
    siteKey <- liftIO $ C.lookup config "siteKey"
    let sk = maybe id (\x s -> s { asSiteKey = x }) siteKey
    return $ (pw . rc . rp . lo . sk) defAuthSettings


------------------------------------------------------------------------------
-- | Initializer for the postgres backend to the auth snaplet.
--
initPostgresAuth
  :: Lens b (Snaplet SessionManager)  -- ^ Lens to the session snaplet
  -> Snaplet Postgres  -- ^ The postgres snaplet
  -> SnapletInit b (AuthManager b)
initPostgresAuth sess db = makeSnaplet "postgresql-auth" desc datadir $ do
    config <- getSnapletUserConfig
    authTable <- liftIO $ C.lookupDefault "snap_auth_user" config "authTable"
    authSettings <- settingsFromConfig
    key <- liftIO $ getKey (asSiteKey authSettings)
    let tableDesc = defAuthTable { tblName = authTable }
    let manager = PostgresAuthManager tableDesc $
                                      pgPool $ getL snapletValue db
    liftIO $ createTableIfMissing manager
    rng <- liftIO mkRNG
    return $ AuthManager
      { backend = manager
      , session = sess
      , activeUser = Nothing
      , minPasswdLen = asMinPasswdLen authSettings
      , rememberCookieName = asRememberCookieName authSettings
      , rememberPeriod = asRememberPeriod authSettings
      , siteKey = key
      , lockout = asLockout authSettings
      , randomNumberGenerator = rng
      }
  where
    desc = "A PostgreSQL backend for user authentication"
    datadir = Just $ liftM (++"/resources/auth") getDataDir


------------------------------------------------------------------------------
-- | Create the user table if it doesn't exist.
createTableIfMissing :: PostgresAuthManager -> IO ()
createTableIfMissing PostgresAuthManager{..} = do
    withResource pamConnPool $ \conn -> do
        res <- P.query_ conn $ Query $ T.encodeUtf8 $
          "select relname from pg_class where relname='"
          `T.append` tblName pamTable `T.append` "'"
        when (null (res :: [Only T.Text])) $
          P.execute_ conn (Query q) >> return ()
    return ()
  where
    q = T.encodeUtf8 $ "CREATE TABLE " `T.append`
                       tblName pamTable `T.append`
                       " (" `T.append`
          T.intercalate "," (map (fDesc . ($pamTable) . (fst)) colDef)

buildUid :: Int -> UserId
buildUid = UserId . T.pack . show


instance Result UserId where
    convert f v = buildUid <$> convert f v

instance Result Password where
    convert f v = Encrypted <$> convert f v

instance QueryResults AuthUser where
    convertResults (fa:fb:fc:fd:fe:ff:fg:fh:fi:fj:fk:fl:fm:fn:fo:_)
                   (va:vb:vc:vd:ve:vf:vg:vh:vi:vj:vk:vl:vm:vn:vo:_) =
        AuthUser
        <$> _userId
        <*> _userLogin
        <*> _userPassword
        <*> _userActivatedAt
        <*> _userSuspendedAt
        <*> _userRememberToken
        <*> _userLoginCount
        <*> _userFailedLoginCount
        <*> _userLockedOutUntil
        <*> _userCurrentLoginAt
        <*> _userLastLoginAt
        <*> _userCurrentLoginIp
        <*> _userLastLoginIp
        <*> _userCreatedAt
        <*> _userUpdatedAt
        <*> _userRoles
        <*> _userMeta
      where
        !_userId               = convert fa va
        !_userLogin            = convert fb vb
        !_userPassword         = convert fc vc
        !_userActivatedAt      = convert fd vd
        !_userSuspendedAt      = convert fe ve
        !_userRememberToken    = convert ff vf
        !_userLoginCount       = convert fg vg
        !_userFailedLoginCount = convert fh vh
        !_userLockedOutUntil   = convert fi vi
        !_userCurrentLoginAt   = convert fj vj
        !_userLastLoginAt      = convert fk vk
        !_userCurrentLoginIp   = convert fl vl
        !_userLastLoginIp      = convert fm vm
        !_userCreatedAt        = convert fn vn
        !_userUpdatedAt        = convert fo vo
        !_userRoles            = Right []
        !_userMeta             = Right HM.empty
    convertResults fs vs = convertError fs vs 15


querySingle :: (QueryParams q, QueryResults a)
            => Pool P.Connection -> Query -> q -> IO (Maybe a)
querySingle pool q ps = withResource pool $ \conn -> return . listToMaybe =<<
    P.query conn q ps

authExecute :: QueryParams q
            => Pool P.Connection -> Query -> q -> IO ()
authExecute pool q ps = do
    withResource pool $ \conn -> P.execute conn q ps
    return ()

instance P.Param Password where
    render (ClearText bs) = P.render bs
    render (Encrypted bs) = P.render bs


-- | Datatype containing the names of the columns for the authentication table.
data AuthTable
  =  AuthTable
  {  tblName             :: Text
  ,  colId               :: (Text, Text)
  ,  colLogin            :: (Text, Text)
  ,  colPassword         :: (Text, Text)
  ,  colActivatedAt      :: (Text, Text)
  ,  colSuspendedAt      :: (Text, Text)
  ,  colRememberToken    :: (Text, Text)
  ,  colLoginCount       :: (Text, Text)
  ,  colFailedLoginCount :: (Text, Text)
  ,  colLockedOutUntil   :: (Text, Text)
  ,  colCurrentLoginAt   :: (Text, Text)
  ,  colLastLoginAt      :: (Text, Text)
  ,  colCurrentLoginIp   :: (Text, Text)
  ,  colLastLoginIp      :: (Text, Text)
  ,  colCreatedAt        :: (Text, Text)
  ,  colUpdatedAt        :: (Text, Text)
  ,  rolesTable          :: Text
  }

-- | Default authentication table layout
defAuthTable :: AuthTable
defAuthTable
  =  AuthTable
  {  tblName             = "snap_auth_user"
  ,  colId               = ("uid", "SERIAL PRIMARY KEY")
  ,  colLogin            = ("login", "text UNIQUE NOT NULL")
  ,  colPassword         = ("password", "text")
  ,  colActivatedAt      = ("activated_at", "timestamp")
  ,  colSuspendedAt      = ("suspended_at", "timestamp")
  ,  colRememberToken    = ("remember_token", "text")
  ,  colLoginCount       = ("login_count", "integer NOT NULL")
  ,  colFailedLoginCount = ("failed_login_count", "integer NOT NULL")
  ,  colLockedOutUntil   = ("locked_out_until", "timestamp")
  ,  colCurrentLoginAt   = ("current_login_at", "timestamp")
  ,  colLastLoginAt      = ("last_login_at", "timestamp")
  ,  colCurrentLoginIp   = ("current_login_ip", "text")
  ,  colLastLoginIp      = ("last_login_ip", "text")
  ,  colCreatedAt        = ("created_at", "timestamp")
  ,  colUpdatedAt        = ("updated_at", "timestamp")
  ,  rolesTable          = "user_roles"
  }

fDesc :: (Text, Text) -> Text
fDesc f = fst f `T.append` " " `T.append` snd f

-- | List of deconstructors so it's easier to extract column names from an
-- 'AuthTable'.
colDef :: [(AuthTable -> (Text, Text), AuthUser -> P.Action)]
colDef =
  [ (colLogin           , P.render . userLogin)
  , (colPassword        , P.render . userPassword)
  , (colActivatedAt     , P.render . userActivatedAt)
  , (colSuspendedAt     , P.render . userSuspendedAt)
  , (colRememberToken   , P.render . userRememberToken)
  , (colLoginCount      , P.render . userLoginCount)
  , (colFailedLoginCount, P.render . userFailedLoginCount)
  , (colLockedOutUntil  , P.render . userLockedOutUntil)
  , (colCurrentLoginAt  , P.render . userCurrentLoginAt)
  , (colLastLoginAt     , P.render . userLastLoginAt)
  , (colCurrentLoginIp  , P.render . userCurrentLoginIp)
  , (colLastLoginIp     , P.render . userLastLoginIp)
  , (colCreatedAt       , P.render . userCreatedAt)
  , (colUpdatedAt       , P.render . userUpdatedAt)
  ]

saveQuery :: AuthTable -> AuthUser -> (Text, [P.Action])
saveQuery at u@AuthUser{..} = maybe insertQuery updateQuery userId
  where
    insertQuery =  (T.concat [ "INSERT INTO "
                             , tblName at
                             , " ("
                             , T.intercalate "," cols
                             , ") VALUES ("
                             , T.intercalate "," vals
                             , ")"
                             ]
                   , params)
    qval f  = fst (f at) `T.append` " = ?"
    updateQuery uid =
        (T.concat [ "UPDATE "
                  , tblName at
                  , " SET "
                  , T.intercalate "," (map (qval . fst) colDef)
                  , " WHERE "
                  , fst (colId at)
                  , " = ?"
                  ]
        , params ++ [P.render $ unUid uid])
    cols = map (fst . ($at) . fst) colDef
    vals = map (const "?") cols
    params = map (($u) . snd) colDef
            

------------------------------------------------------------------------------
-- | 
instance IAuthBackend PostgresAuthManager where
    save PostgresAuthManager{..} u@AuthUser{..} = do
        let (qstr, params) = saveQuery pamTable u
        let q = Query $ T.encodeUtf8 qstr
        withResource pamConnPool $ \conn -> do
            P.begin conn
            P.execute conn q params
            let q2 = Query $ T.encodeUtf8 $ T.concat
                     [ "select * from "
                     , tblName pamTable
                     , " where "
                     , fst (colLogin pamTable)
                     , " = ?"
                     ]
            res <- P.query conn q2 [userLogin]
            P.commit conn
            return $ fromMaybe u $ listToMaybe res

    lookupByUserId PostgresAuthManager{..} uid = do
        let q = Query $ T.encodeUtf8 $ T.concat
                [ "select * from "
                , tblName pamTable
                , " where "
                , fst (colId pamTable)
                , " = ?"
                ]
        querySingle pamConnPool q [unUid uid]

    lookupByLogin PostgresAuthManager{..} login = do
        let q = Query $ T.encodeUtf8 $ T.concat
                [ "select * from "
                , tblName pamTable
                , " where "
                , fst (colLogin pamTable)
                , " = ?"
                ]
        querySingle pamConnPool q [login]

    lookupByRememberToken PostgresAuthManager{..} token = do
        let q = Query $ T.encodeUtf8 $ T.concat
                [ "select * from "
                , tblName pamTable
                , " where "
                , fst (colRememberToken pamTable)
                , " = ?"
                ]
        querySingle pamConnPool q [token]

    destroy PostgresAuthManager{..} AuthUser{..} = do
        let q = Query $ T.encodeUtf8 $ T.concat
                [ "delete from "
                , tblName pamTable
                , " where "
                , fst (colLogin pamTable)
                , " = ?"
                ]
        authExecute pamConnPool q [userLogin]

