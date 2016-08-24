{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE CPP               #-}
module Yesod.Core.Class.Yesod where

import           Yesod.Core.Content
import           Yesod.Core.Handler

import           Yesod.Routes.Class

import           Blaze.ByteString.Builder           (Builder, toByteString)
import           Blaze.ByteString.Builder.ByteString (copyByteString)
import           Blaze.ByteString.Builder.Char.Utf8 (fromText, fromChar)
import           Control.Arrow                      ((***), second)
import           Control.Exception                  (bracket)
#if __GLASGOW_HASKELL__ < 710
import           Control.Applicative                ((<$>))
#endif
import           Control.Monad                      (forM, when, void)
import           Control.Monad.IO.Class             (MonadIO (liftIO))
import           Control.Monad.Logger               (LogLevel (LevelInfo, LevelOther),
                                                     LogSource, logErrorS)
import           Control.Monad.Trans.Resource       (InternalState, createInternalState, closeInternalState)
import qualified Data.ByteString.Char8              as S8
import qualified Data.ByteString.Lazy               as L
import Data.Aeson (object, (.=))
import           Data.List                          (foldl', nub)
import qualified Data.Map                           as Map
import           Data.Monoid
import           Data.Text                          (Text)
import qualified Data.Text                          as T
import qualified Data.Text.Encoding                 as TE
import qualified Data.Text.Encoding.Error           as TEE
import           Data.Text.Lazy.Builder             (toLazyText)
import           Data.Text.Lazy.Encoding            (encodeUtf8)
import           Data.Word                          (Word64)
import           Language.Haskell.TH.Syntax         (Loc (..))
import           Network.HTTP.Types                 (encodePath, renderQueryText)
import qualified Network.Wai                        as W
import           Data.Default                       (def)
import           Network.Wai.Parse                  (lbsBackEnd,
                                                     tempFileBackEnd)
import           Network.Wai.Logger                 (ZonedDate, clockDateCacher)
import           System.Log.FastLogger
import           Text.Blaze                         (customAttribute, textTag,
                                                     toValue, (!),
                                                     preEscapedToMarkup)
import qualified Text.Blaze.Html5                   as TBH
import           Text.Hamlet
import           Text.Julius
import qualified Web.ClientSession                  as CS
import           Web.Cookie                         (SetCookie (..), parseCookies, sameSiteLax,
                                                     sameSiteStrict, SameSiteOption)
import           Yesod.Core.Types
import           Yesod.Core.Internal.Session
import           Yesod.Core.Widget
import Control.Monad.Trans.Class (lift)
import Data.CaseInsensitive (CI)
import qualified Network.Wai.Request

-- | Define settings for a Yesod applications. All methods have intelligent
-- defaults, and therefore no implementation is required.
class RenderRoute site => Yesod site where
    -- | An absolute URL to the root of the application. Do not include
    -- trailing slash.
    --
    -- Default value: 'ApprootRelative'. This is valid under the following
    -- conditions:
    --
    -- * Your application is served from the root of the domain.
    --
    -- * You do not use any features that require absolute URLs, such as Atom
    -- feeds and XML sitemaps.
    --
    -- If this is not true, you should override with a different
    -- implementation.
    approot :: Approot site
    approot = ApprootRelative

    -- | Output error response pages.
    --
    -- Default value: 'defaultErrorHandler'.
    errorHandler :: ErrorResponse -> HandlerT site IO TypedContent
    errorHandler = defaultErrorHandler

    -- | Applies some form of layout to the contents of a page.
    defaultLayout :: WidgetT site IO () -> HandlerT site IO Html
    defaultLayout w = do
        p <- widgetToPageContent w
        msgs <- getMessages
        withUrlRenderer [hamlet|
            $newline never
            $doctype 5
            <html>
                <head>
                    <title>#{pageTitle p}
                    ^{pageHead p}
                <body>
                    $forall (status, msg) <- msgs
                        <p class="message #{status}">#{msg}
                    ^{pageBody p}
            |]

    -- | Override the rendering function for a particular URL. One use case for
    -- this is to offload static hosting to a different domain name to avoid
    -- sending cookies.
    urlRenderOverride :: site -> Route site -> Maybe Builder
    urlRenderOverride _ _ = Nothing

    -- | Override the rendering function for a particular URL and query string
    -- parameters. One use case for this is to offload static hosting to a
    -- different domain name to avoid sending cookies.
    -- 
    -- For backward compatibility default implementation is in terms of
    -- 'urlRenderOverride', probably ineffective
    -- 
    -- Since 1.4.23
    urlParamRenderOverride :: site
                           -> Route site
                           -> [(T.Text, T.Text)] -- ^ query string
                           -> Maybe Builder
    urlParamRenderOverride y route params = addParams params <$> urlRenderOverride y route
      where
        addParams [] routeBldr = routeBldr
        addParams nonEmptyParams routeBldr =
            let routeBS = toByteString routeBldr
                qsSeparator = fromChar $ if S8.elem '?' routeBS then '&' else '?'
                valueToMaybe t = if t == "" then Nothing else Just t
                queryText = map (id *** valueToMaybe) nonEmptyParams
            in copyByteString routeBS `mappend` qsSeparator `mappend` renderQueryText False queryText

    -- | Determine if a request is authorized or not.
    --
    -- Return 'Authorized' if the request is authorized,
    -- 'Unauthorized' a message if unauthorized.
    -- If authentication is required, return 'AuthenticationRequired'.
    isAuthorized :: Route site
                 -> Bool -- ^ is this a write request?
                 -> HandlerT site IO AuthResult
    isAuthorized _ _ = return Authorized

    -- | Determines whether the current request is a write request. By default,
    -- this assumes you are following RESTful principles, and determines this
    -- from request method. In particular, all except the following request
    -- methods are considered write: GET HEAD OPTIONS TRACE.
    --
    -- This function is used to determine if a request is authorized; see
    -- 'isAuthorized'.
    isWriteRequest :: Route site -> HandlerT site IO Bool
    isWriteRequest _ = do
        wai <- waiRequest
        return $ W.requestMethod wai `notElem`
            ["GET", "HEAD", "OPTIONS", "TRACE"]

    -- | The default route for authentication.
    --
    -- Used in particular by 'isAuthorized', but library users can do whatever
    -- they want with it.
    authRoute :: site -> Maybe (Route site)
    authRoute _ = Nothing

    -- | A function used to clean up path segments. It returns 'Right' with a
    -- clean path or 'Left' with a new set of pieces the user should be
    -- redirected to. The default implementation enforces:
    --
    -- * No double slashes
    --
    -- * There is no trailing slash.
    --
    -- Note that versions of Yesod prior to 0.7 used a different set of rules
    -- involing trailing slashes.
    cleanPath :: site -> [Text] -> Either [Text] [Text]
    cleanPath _ s =
        if corrected == s
            then Right $ map dropDash s
            else Left corrected
      where
        corrected = filter (not . T.null) s
        dropDash t
            | T.all (== '-') t = T.drop 1 t
            | otherwise = t

    -- | Builds an absolute URL by concatenating the application root with the
    -- pieces of a path and a query string, if any.
    -- Note that the pieces of the path have been previously cleaned up by 'cleanPath'.
    joinPath :: site
             -> T.Text -- ^ application root
             -> [T.Text] -- ^ path pieces
             -> [(T.Text, T.Text)] -- ^ query string
             -> Builder
    joinPath _ ar pieces' qs' =
        fromText ar `mappend` encodePath pieces qs
      where
        pieces = if null pieces' then [""] else map addDash pieces'
        qs = map (TE.encodeUtf8 *** go) qs'
        go "" = Nothing
        go x = Just $ TE.encodeUtf8 x
        addDash t
            | T.all (== '-') t = T.cons '-' t
            | otherwise = t

    -- | This function is used to store some static content to be served as an
    -- external file. The most common case of this is stashing CSS and
    -- JavaScript content in an external file; the "Yesod.Widget" module uses
    -- this feature.
    --
    -- The return value is 'Nothing' if no storing was performed; this is the
    -- default implementation. A 'Just' 'Left' gives the absolute URL of the
    -- file, whereas a 'Just' 'Right' gives the type-safe URL. The former is
    -- necessary when you are serving the content outside the context of a
    -- Yesod application, such as via memcached.
    addStaticContent :: Text -- ^ filename extension
                     -> Text -- ^ mime-type
                     -> L.ByteString -- ^ content
                     -> HandlerT site IO (Maybe (Either Text (Route site, [(Text, Text)])))
    addStaticContent _ _ _ = return Nothing

    -- | Maximum allowed length of the request body, in bytes.
    --
    -- If @Nothing@, no maximum is applied.
    --
    -- Default: 2 megabytes.
    maximumContentLength :: site -> Maybe (Route site) -> Maybe Word64
    maximumContentLength _ _ = Just $ 2 * 1024 * 1024 -- 2 megabytes

    -- | Creates a @Logger@ to use for log messages.
    --
    -- Note that a common technique (endorsed by the scaffolding) is to create
    -- a @Logger@ value and place it in your foundation datatype, and have this
    -- method return that already created value. That way, you can use that
    -- same @Logger@ for printing messages during app initialization.
    --
    -- Default: the 'defaultMakeLogger' function.
    makeLogger :: site -> IO Logger
    makeLogger _ = defaultMakeLogger

    -- | Send a message to the @Logger@ provided by @getLogger@.
    --
    -- Default: the 'defaultMessageLoggerSource' function, using
    -- 'shouldLogIO' to check whether we should log.
    messageLoggerSource :: site
                        -> Logger
                        -> Loc -- ^ position in source code
                        -> LogSource
                        -> LogLevel
                        -> LogStr -- ^ message
                        -> IO ()
    messageLoggerSource site = defaultMessageLoggerSource $ shouldLogIO site

    -- | Where to Load sripts from. We recommend the default value,
    -- 'BottomOfBody'.
    jsLoader :: site -> ScriptLoadPosition site
    jsLoader _ = BottomOfBody

    -- | Create a session backend. Returning 'Nothing' disables
    -- sessions. If you'd like to change the way that the session
    -- cookies are created, take a look at
    -- 'customizeSessionCookies'.
    --
    -- Default: Uses clientsession with a 2 hour timeout.
    makeSessionBackend :: site -> IO (Maybe SessionBackend)
    makeSessionBackend _ = Just <$> defaultClientSessionBackend 120 CS.defaultKeyFile

    -- | How to store uploaded files.
    --
    -- Default: When the request body is greater than 50kb, store in a temp
    -- file. For chunked request bodies, store in a temp file. Otherwise, store
    -- in memory.
    fileUpload :: site -> W.RequestBodyLength -> FileUpload
    fileUpload _ (W.KnownLength size)
        | size <= 50000 = FileUploadMemory lbsBackEnd
    fileUpload _ _ = FileUploadDisk tempFileBackEnd

    -- | Should we log the given log source/level combination.
    --
    -- Default: the 'defaultShouldLog' function.
    shouldLog :: site -> LogSource -> LogLevel -> Bool
    shouldLog _ = defaultShouldLog

    -- | Should we log the given log source/level combination.
    --
    -- Note that this is almost identical to @shouldLog@, except the result
    -- lives in @IO@. This allows you to dynamically alter the logging level of
    -- your application by having this result depend on, e.g., an @IORef@.
    --
    -- The default implementation simply uses @shouldLog@. Future versions of
    -- Yesod will remove @shouldLog@ and use this method exclusively.
    --
    -- Since 1.2.4
    shouldLogIO :: site -> LogSource -> LogLevel -> IO Bool
    shouldLogIO a b c = return (shouldLog a b c)

    -- | A Yesod middleware, which will wrap every handler function. This
    -- allows you to run code before and after a normal handler.
    --
    -- Default: the 'defaultYesodMiddleware' function.
    --
    -- Since: 1.1.6
    yesodMiddleware :: ToTypedContent res => HandlerT site IO res -> HandlerT site IO res
    yesodMiddleware = defaultYesodMiddleware

    -- | How to allocate an @InternalState@ for each request.
    --
    -- The default implementation is almost always what you want. However, if
    -- you know that you are never taking advantage of the @MonadResource@
    -- instance in your handler functions, setting this to a dummy
    -- implementation can provide a small optimization. Only do this if you
    -- really know what you're doing, otherwise you can turn safe code into a
    -- runtime error!
    --
    -- Since 1.4.2
    yesodWithInternalState :: site -> Maybe (Route site) -> (InternalState -> IO a) -> IO a
    yesodWithInternalState _ _ = bracket createInternalState closeInternalState
    {-# INLINE yesodWithInternalState #-}
{-# DEPRECATED urlRenderOverride "Use urlParamRenderOverride instead" #-}

-- | Default implementation of 'makeLogger'. Sends to stdout and
-- automatically flushes on each write.
--
-- Since 1.4.10
defaultMakeLogger :: IO Logger
defaultMakeLogger = do
    loggerSet' <- newStdoutLoggerSet defaultBufSize
    (getter, _) <- clockDateCacher
    return $! Logger loggerSet' getter

-- | Default implementation of 'messageLoggerSource'. Checks if the
-- message should be logged using the provided function, and if so,
-- formats using 'formatLogMessage'. You can use 'defaultShouldLogIO'
-- as the provided function.
--
-- Since 1.4.10
defaultMessageLoggerSource ::
       (LogSource -> LogLevel -> IO Bool) -- ^ Check whether we should
                                          -- log this
    -> Logger
    -> Loc -- ^ position in source code
    -> LogSource
    -> LogLevel
    -> LogStr -- ^ message
    -> IO ()
defaultMessageLoggerSource ckLoggable logger loc source level msg = do
    loggable <- ckLoggable source level
    when loggable $
        formatLogMessage (loggerDate logger) loc source level msg >>=
        loggerPutStr logger

-- | Default implementation of 'shouldLog'. Logs everything at or
-- above 'LevelInfo'.
--
-- Since 1.4.10
defaultShouldLog :: LogSource -> LogLevel -> Bool
defaultShouldLog _ level = level >= LevelInfo

-- | A default implementation of 'shouldLogIO' that can be used with
-- 'defaultMessageLoggerSource'. Just uses 'defaultShouldLog'.
--
-- Since 1.4.10
defaultShouldLogIO :: LogSource -> LogLevel -> IO Bool
defaultShouldLogIO a b = return $ defaultShouldLog a b

-- | Default implementation of 'yesodMiddleware'. Adds the response header
-- \"Vary: Accept, Accept-Language\" and performs authorization checks.
--
-- Since 1.2.0
defaultYesodMiddleware :: Yesod site => HandlerT site IO res -> HandlerT site IO res
defaultYesodMiddleware handler = do
    addHeader "Vary" "Accept, Accept-Language"
    authorizationCheck
    handler

-- | Defends against session hijacking by setting the secure bit on session
-- cookies so that browsers will not transmit them over http. With this
-- setting on, it follows that the server will regard requests made over
-- http as sessionless, because the session cookie will not be included in
-- the request. Use this as part of a total security measure which also
-- includes disabling HTTP traffic to the site or issuing redirects from
-- HTTP urls, and composing 'sslOnlyMiddleware' with the site's
-- 'yesodMiddleware'.
--
-- Since 1.4.7
sslOnlySessions :: IO (Maybe SessionBackend) -> IO (Maybe SessionBackend)
sslOnlySessions = (fmap . fmap) secureSessionCookies
  where
    setSecureBit cookie = cookie { setCookieSecure = True }
    secureSessionCookies = customizeSessionCookies setSecureBit

-- | Helps defend against CSRF attacks by setting the SameSite attribute on
-- session cookies to Lax. With the Lax setting, the cookie will be sent with same-site
-- requests, and with cross-site top-level navigations.
--
-- This option is liable to change in future versions of Yesod as the spec evolves.
-- View more information <https://datatracker.ietf.org/doc/draft-west-first-party-cookies/ here>.
--
-- @since 1.4.23
laxSameSiteSessions :: IO (Maybe SessionBackend) -> IO (Maybe SessionBackend)
laxSameSiteSessions = sameSiteSession sameSiteLax

-- | Helps defend against CSRF attacks by setting the SameSite attribute on
-- session cookies to Strict. With the Strict setting, the cookie will only be
-- sent with same-site requests.
--
-- This option is liable to change in future versions of Yesod as the spec evolves.
-- View more information <https://datatracker.ietf.org/doc/draft-west-first-party-cookies/ here>.
--
-- @since 1.4.23
strictSameSiteSessions :: IO (Maybe SessionBackend) -> IO (Maybe SessionBackend)
strictSameSiteSessions = sameSiteSession sameSiteStrict

sameSiteSession :: SameSiteOption -> IO (Maybe SessionBackend) -> IO (Maybe SessionBackend)
sameSiteSession s = (fmap . fmap) secureSessionCookies
  where
    sameSite cookie = cookie { setCookieSameSite = Just s }
    secureSessionCookies = customizeSessionCookies sameSite

-- | Apply a Strict-Transport-Security header with the specified timeout to
-- all responses so that browsers will rewrite all http links to https
-- until the timeout expires. For security, the max-age of the STS header
-- should always equal or exceed the client sessions timeout. This defends
-- against SSL-stripping man-in-the-middle attacks. It is only effective if
-- a secure connection has already been made; Strict-Transport-Security
-- headers are ignored over HTTP.
--
-- Since 1.4.7
sslOnlyMiddleware :: Yesod site
                     => Int -- ^ minutes
                     -> HandlerT site IO res
                     -> HandlerT site IO res
sslOnlyMiddleware timeout handler = do
    addHeader "Strict-Transport-Security"
              $ T.pack $ concat [ "max-age="
                                , show $ timeout * 60
                                , "; includeSubDomains"
                                ]
    handler

-- | Check if a given request is authorized via 'isAuthorized' and
-- 'isWriteRequest'.
--
-- Since 1.2.0
authorizationCheck :: Yesod site => HandlerT site IO ()
authorizationCheck = getCurrentRoute >>= maybe (return ()) checkUrl
  where
    checkUrl url = do
        isWrite <- isWriteRequest url
        ar <- isAuthorized url isWrite
        case ar of
            Authorized -> return ()
            AuthenticationRequired -> do
                master <- getYesod
                case authRoute master of
                    Nothing -> void notAuthenticated
                    Just url' ->
                      void $ selectRep $ do
                          provideRepType typeHtml $ do
                              setUltDestCurrent
                              void $ redirect url'
                          provideRepType typeJson $
                              void notAuthenticated
            Unauthorized s' -> permissionDenied s'

-- | Calls 'csrfCheckMiddleware' with 'isWriteRequest', 'defaultCsrfHeaderName', and 'defaultCsrfParamName' as parameters.
--
-- Since 1.4.14
defaultCsrfCheckMiddleware :: Yesod site => HandlerT site IO res -> HandlerT site IO res
defaultCsrfCheckMiddleware handler =
    csrfCheckMiddleware
        handler
        (getCurrentRoute >>= maybe (return False) isWriteRequest)
        defaultCsrfHeaderName
        defaultCsrfParamName

-- | Looks up the CSRF token from the request headers or POST parameters. If the value doesn't match the token stored in the session,
-- this function throws a 'PermissionDenied' error.
--
-- For details, see the "AJAX CSRF protection" section of "Yesod.Core.Handler".
--
-- Since 1.4.14
csrfCheckMiddleware :: Yesod site
                    => HandlerT site IO res
                    -> HandlerT site IO Bool -- ^ Whether or not to perform the CSRF check.
                    -> CI S8.ByteString -- ^ The header name to lookup the CSRF token from.
                    -> Text -- ^ The POST parameter name to lookup the CSRF token from.
                    -> HandlerT site IO res
csrfCheckMiddleware handler shouldCheckFn headerName paramName = do
    shouldCheck <- shouldCheckFn
    when shouldCheck (checkCsrfHeaderOrParam headerName paramName)
    handler

-- | Calls 'csrfSetCookieMiddleware' with the 'defaultCsrfCookieName'.
--
-- The cookie's path is set to @/@, making it valid for your whole website.
--
-- Since 1.4.14
defaultCsrfSetCookieMiddleware :: Yesod site => HandlerT site IO res -> HandlerT site IO res
defaultCsrfSetCookieMiddleware handler = setCsrfCookie >> handler

-- | Takes a 'SetCookie' and overrides its value with a CSRF token, then sets the cookie. See 'setCsrfCookieWithCookie'.
--
-- For details, see the "AJAX CSRF protection" section of "Yesod.Core.Handler".
--
-- Make sure to set the 'setCookiePath' to the root path of your application, otherwise you'll generate a new CSRF token for every path of your app. If your app is run from from e.g. www.example.com\/app1, use @app1@. The vast majority of sites will just use @/@.
--
-- Since 1.4.14
csrfSetCookieMiddleware :: Yesod site => HandlerT site IO res -> SetCookie -> HandlerT site IO res
csrfSetCookieMiddleware handler cookie = setCsrfCookieWithCookie cookie >> handler

-- | Calls 'defaultCsrfSetCookieMiddleware' and 'defaultCsrfCheckMiddleware'.
--
-- For details, see the "AJAX CSRF protection" section of "Yesod.Core.Handler".
--
-- You can add this chain this middleware together with other middleware like so:
--
-- @
-- 'yesodMiddleware' = 'defaultYesodMiddleware' . 'defaultCsrfMiddleware'
-- @
--
-- or:
--
-- @
-- 'yesodMiddleware' app = 'defaultYesodMiddleware' $ 'defaultCsrfMiddleware' $ app
-- @
--
-- Since 1.4.14
defaultCsrfMiddleware :: Yesod site => HandlerT site IO res -> HandlerT site IO res
defaultCsrfMiddleware = defaultCsrfSetCookieMiddleware . defaultCsrfCheckMiddleware

-- | Convert a widget to a 'PageContent'.
widgetToPageContent :: (Eq (Route site), Yesod site)
                    => WidgetT site IO ()
                    -> HandlerT site IO (PageContent (Route site))
widgetToPageContent w = do
    master <- getYesod
    hd <- HandlerT return
    ((), GWData (Body body) (Last mTitle) scripts' stylesheets' style jscript (Head head')) <- lift $ unWidgetT w hd
    let title = maybe mempty unTitle mTitle
        scripts = runUniqueList scripts'
        stylesheets = runUniqueList stylesheets'

    render <- getUrlRenderParams
    let renderLoc x =
            case x of
                Nothing -> Nothing
                Just (Left s) -> Just s
                Just (Right (u, p)) -> Just $ render u p
    css <- forM (Map.toList style) $ \(mmedia, content) -> do
        let rendered = toLazyText $ content render
        x <- addStaticContent "css" "text/css; charset=utf-8"
           $ encodeUtf8 rendered
        return (mmedia,
            case x of
                Nothing -> Left $ preEscapedToMarkup rendered
                Just y -> Right $ either id (uncurry render) y)
    jsLoc <-
        case jscript of
            Nothing -> return Nothing
            Just s -> do
                x <- addStaticContent "js" "text/javascript; charset=utf-8"
                   $ encodeUtf8 $ renderJavascriptUrl render s
                return $ renderLoc x

    -- modernizr should be at the end of the <head> http://www.modernizr.com/docs/#installing
    -- the asynchronous loader means your page doesn't have to wait for all the js to load
    let (mcomplete, asyncScripts) = asyncHelper render scripts jscript jsLoc
        regularScriptLoad = [hamlet|
            $newline never
            $forall s <- scripts
                ^{mkScriptTag s}
            $maybe j <- jscript
                $maybe s <- jsLoc
                    <script src="#{s}">
                $nothing
                    <script>^{jelper j}
        |]

        headAll = [hamlet|
            $newline never
            \^{head'}
            $forall s <- stylesheets
                ^{mkLinkTag s}
            $forall s <- css
                $maybe t <- right $ snd s
                    $maybe media <- fst s
                        <link rel=stylesheet media=#{media} href=#{t}>
                    $nothing
                        <link rel=stylesheet href=#{t}>
                $maybe content <- left $ snd s
                    $maybe media <- fst s
                        <style media=#{media}>#{content}
                    $nothing
                        <style>#{content}
            $case jsLoader master
              $of BottomOfBody
              $of BottomOfHeadAsync asyncJsLoader
                  ^{asyncJsLoader asyncScripts mcomplete}
              $of BottomOfHeadBlocking
                  ^{regularScriptLoad}
        |]
    let bodyScript = [hamlet|
            $newline never
            ^{body}
            ^{regularScriptLoad}
        |]

    return $ PageContent title headAll $
        case jsLoader master of
            BottomOfBody -> bodyScript
            _ -> body
  where
    renderLoc' render' (Local url) = render' url []
    renderLoc' _ (Remote s) = s

    addAttr x (y, z) = x ! customAttribute (textTag y) (toValue z)
    mkScriptTag (Script loc attrs) render' =
        foldl' addAttr TBH.script (("src", renderLoc' render' loc) : attrs) $ return ()
    mkLinkTag (Stylesheet loc attrs) render' =
        foldl' addAttr TBH.link
            ( ("rel", "stylesheet")
            : ("href", renderLoc' render' loc)
            : attrs
            )

    runUniqueList :: Eq x => UniqueList x -> [x]
    runUniqueList (UniqueList x) = nub $ x []

-- | The default error handler for 'errorHandler'.
defaultErrorHandler :: Yesod site => ErrorResponse -> HandlerT site IO TypedContent
defaultErrorHandler NotFound = selectRep $ do
    provideRep $ defaultLayout $ do
        r <- waiRequest
        let path' = TE.decodeUtf8With TEE.lenientDecode $ W.rawPathInfo r
        setTitle "Not Found"
        toWidget [hamlet|
            <h1>Not Found
            <p>#{path'}
        |]
    provideRep $ return $ object ["message" .= ("Not Found" :: Text)]

-- For API requests.
-- For a user with a browser,
-- if you specify an authRoute the user will be redirected there and
-- this page will not be shown.
defaultErrorHandler NotAuthenticated = selectRep $ do
    provideRep $ defaultLayout $ do
        setTitle "Not logged in"
        toWidget [hamlet|
            <h1>Not logged in
            <p style="display:none;">Set the authRoute and the user will be redirected there.
        |]

    provideRep $ do
        -- 401 *MUST* include a WWW-Authenticate header
        -- however, there is no standard to indicate a redirection
        --
        -- change this to Basic or Digest if you allow those forms of authentications
        addHeader "WWW-Authenticate" "RedirectJSON realm=\"application\", param=\"authentication_url\""

        -- The client will just use the authentication_url in the JSON
        site <- getYesod
        rend <- getUrlRender
        let apair u = ["authentication_url" .= rend u]
            content = maybe [] apair (authRoute site)
        return $ object $ ("message" .= ("Not logged in"::Text)):content

defaultErrorHandler (PermissionDenied msg) = selectRep $ do
    provideRep $ defaultLayout $ do
        setTitle "Permission Denied"
        toWidget [hamlet|
            <h1>Permission denied
            <p>#{msg}
        |]
    provideRep $
        return $ object ["message" .= ("Permission Denied. " <> msg)]

defaultErrorHandler (InvalidArgs ia) = selectRep $ do
    provideRep $ defaultLayout $ do
        setTitle "Invalid Arguments"
        toWidget [hamlet|
            <h1>Invalid Arguments
            <ul>
                $forall msg <- ia
                    <li>#{msg}
        |]
    provideRep $ return $ object ["message" .= ("Invalid Arguments" :: Text), "errors" .= ia]
defaultErrorHandler (InternalError e) = do
    $logErrorS "yesod-core" e
    selectRep $ do
        provideRep $ defaultLayout $ do
            setTitle "Internal Server Error"
            toWidget [hamlet|
                <h1>Internal Server Error
                <pre>#{e}
            |]
        provideRep $ return $ object ["message" .= ("Internal Server Error" :: Text), "error" .= e]
defaultErrorHandler (BadMethod m) = selectRep $ do
    provideRep $ defaultLayout $ do
        setTitle"Bad Method"
        toWidget [hamlet|
            <h1>Method Not Supported
            <p>Method <code>#{S8.unpack m}</code> not supported
        |]
    provideRep $ return $ object ["message" .= ("Bad method" :: Text), "method" .= TE.decodeUtf8With TEE.lenientDecode m]

asyncHelper :: (url -> [x] -> Text)
         -> [Script url]
         -> Maybe (JavascriptUrl url)
         -> Maybe Text
         -> (Maybe (HtmlUrl url), [Text])
asyncHelper render scripts jscript jsLoc =
    (mcomplete, scripts'')
  where
    scripts' = map goScript scripts
    scripts'' =
        case jsLoc of
            Just s -> scripts' ++ [s]
            Nothing -> scripts'
    goScript (Script (Local url) _) = render url []
    goScript (Script (Remote s) _) = s
    mcomplete =
        case jsLoc of
            Just{} -> Nothing
            Nothing ->
                case jscript of
                    Nothing -> Nothing
                    Just j -> Just $ jelper j

-- | Default formatting for log messages. When you use
-- the template haskell logging functions for to log with information
-- about the source location, that information will be appended to
-- the end of the log. When you use the non-TH logging functions,
-- like 'logDebugN', this function does not include source
-- information. This currently works by checking to see if the
-- package name is the string \"\<unknown\>\". This is a hack,
-- but it removes some of the visual clutter from non-TH logs.
--
-- Since 1.4.10
formatLogMessage :: IO ZonedDate
                 -> Loc
                 -> LogSource
                 -> LogLevel
                 -> LogStr -- ^ message
                 -> IO LogStr
formatLogMessage getdate loc src level msg = do
    now <- getdate
    return $ mempty
        `mappend` toLogStr now
        `mappend` " ["
        `mappend` (case level of
            LevelOther t -> toLogStr t
            _ -> toLogStr $ drop 5 $ show level)
        `mappend` (if T.null src
            then mempty
            else "#" `mappend` toLogStr src)
        `mappend` "] "
        `mappend` msg
        `mappend` sourceSuffix
        `mappend` "\n"
    where
    sourceSuffix = if loc_package loc == "<unknown>" then "" else mempty
        `mappend` " @("
        `mappend` toLogStr (fileLocationToString loc)
        `mappend` ")"

-- | Customize the cookies used by the session backend.  You may
-- use this function on your definition of 'makeSessionBackend'.
--
-- For example, you could set the cookie domain so that it
-- would work across many subdomains:
--
-- @
-- makeSessionBackend site =
--     (fmap . fmap) (customizeSessionCookies addDomain) ...
--   where
--     addDomain cookie = cookie { 'setCookieDomain' = Just \".example.com\" }
-- @
--
-- Default: Do not customize anything ('id').
customizeSessionCookies :: (SetCookie -> SetCookie) -> (SessionBackend -> SessionBackend)
customizeSessionCookies customizeCookie backend = backend'
  where
    customizeHeader (AddCookie cookie) = AddCookie (customizeCookie cookie)
    customizeHeader other              = other
    customizeSaveSession = (fmap . fmap . fmap) customizeHeader
    backend' =
      backend {
        sbLoadSession = \req ->
          second customizeSaveSession `fmap` sbLoadSession backend req
      }


defaultClientSessionBackend :: Int -- ^ minutes
                            -> FilePath -- ^ key file
                            -> IO SessionBackend
defaultClientSessionBackend minutes fp = do
  key <- CS.getKey fp
  (getCachedDate, _closeDateCacher) <- clientSessionDateCacher (minToSec minutes)
  return $ clientSessionBackend key getCachedDate

-- | Create a @SessionBackend@ which reads the session key from the named
-- environment variable.
--
-- This can be useful if:
--
-- 1. You can't rely on a persistent file system (e.g. Heroku)
-- 2. Your application is open source (e.g. you can't commit the key)
--
-- By keeping a consistent value in the environment variable, your users will
-- have consistent sessions without relying on the file system.
--
-- Note: A suitable value should only be obtained in one of two ways:
--
-- 1. Run this code without the variable set, a value will be generated and
--    printed on @/dev/stdout/@
-- 2. Use @clientsession-generate@
--
-- Since 1.4.5
envClientSessionBackend :: Int -- ^ minutes
                        -> String -- ^ environment variable name
                        -> IO SessionBackend
envClientSessionBackend minutes name = do
    key <- CS.getKeyEnv name
    (getCachedDate, _closeDateCacher) <- clientSessionDateCacher $ minToSec minutes
    return $ clientSessionBackend key getCachedDate

minToSec :: (Integral a, Num b) => a -> b
minToSec minutes = fromIntegral (minutes * 60)

jsToHtml :: Javascript -> Html
jsToHtml (Javascript b) = preEscapedToMarkup $ toLazyText b

jelper :: JavascriptUrl url -> HtmlUrl url
jelper = fmap jsToHtml

left :: Either a b -> Maybe a
left (Left x) = Just x
left _ = Nothing

right :: Either a b -> Maybe b
right (Right x) = Just x
right _ = Nothing

clientSessionBackend :: CS.Key  -- ^ The encryption key
                     -> IO ClientSessionDateCache -- ^ See 'clientSessionDateCacher'
                     -> SessionBackend
clientSessionBackend key getCachedDate =
  SessionBackend {
    sbLoadSession = loadClientSession key getCachedDate "_SESSION"
  }

loadClientSession :: CS.Key
                  -> IO ClientSessionDateCache -- ^ See 'clientSessionDateCacher'
                  -> S8.ByteString -- ^ session name
                  -> W.Request
                  -> IO (SessionMap, SaveSession)
loadClientSession key getCachedDate sessionName req = load
  where
    load = do
      date <- getCachedDate
      return (sess date, save date)
    sess date = Map.unions $ do
      raw <- [v | (k, v) <- W.requestHeaders req, k == "Cookie"]
      val <- [v | (k, v) <- parseCookies raw, k == sessionName]
      let host = "" -- fixme, properly lock sessions to client address
      maybe [] return $ decodeClientSession key date host val
    save date sess' = do
      -- We should never cache the IV!  Be careful!
      iv <- liftIO CS.randomIV
      return [AddCookie def
          { setCookieName = sessionName
          , setCookieValue = encodeClientSession key iv date host sess'
          , setCookiePath = Just "/"
          , setCookieExpires = Just (csdcExpires date)
          , setCookieDomain = Nothing
          , setCookieHttpOnly = True
          }]
        where
          host = "" -- fixme, properly lock sessions to client address

-- taken from file-location package
-- turn the TH Loc loaction information into a human readable string
-- leaving out the loc_end parameter
fileLocationToString :: Loc -> String
fileLocationToString loc =
    concat
      [ loc_package loc
      , ':' : loc_module loc
      , ' ' : loc_filename loc
      , ':' : line loc
      , ':' : char loc
      ]
  where
    line = show . fst . loc_start
    char = show . snd . loc_start

-- | Guess the approot based on request headers. For more information, see
-- "Network.Wai.Middleware.Approot"
--
-- In the case of headers being unavailable, it falls back to 'ApprootRelative'
--
-- Since 1.4.16
guessApproot :: Approot site
guessApproot = guessApprootOr ApprootRelative

-- | Guess the approot based on request headers, with fall back to the
-- specified 'AppRoot'.
--
-- Since 1.4.16
guessApprootOr :: Approot site -> Approot site
guessApprootOr fallback = ApprootRequest $ \master req ->
    case W.requestHeaderHost req of
        Nothing -> getApprootText fallback master req
        Just host ->
            (if Network.Wai.Request.appearsSecure req
                then "https://"
                else "http://")
            `T.append` TE.decodeUtf8With TEE.lenientDecode host

-- | Get the textual application root from an 'Approot' value.
--
-- Since 1.4.17
getApprootText :: Approot site -> site -> W.Request -> Text
getApprootText ar site req =
    case ar of
        ApprootRelative -> ""
        ApprootStatic t -> t
        ApprootMaster f -> f site
        ApprootRequest f -> f site req
