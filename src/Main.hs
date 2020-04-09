{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Control.Monad ((<=<))
import System.Environment(getArgs)
import System.IO.Unsafe (unsafePerformIO)
import System.IO.Error (tryIOError)
import qualified System.Process.Typed as TP
import System.Exit (ExitCode(ExitSuccess), exitSuccess, exitFailure)
import System.Directory (createDirectory, doesDirectoryExist)
import qualified System.Posix.DynamicLinker as DL
import Codec.Binary.UTF8.String (decode)
import Data.ByteString (pack)
import Data.ByteString.UTF8 (toString)
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.UTF8 as U
import Data.Int  (Int32, Int64)
import Data.Word (Word8)
import Foreign.Ptr (Ptr,FunPtr,castFunPtrToPtr,nullFunPtr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Storable (Storable, peek)
import Data.List (unfoldr, foldl')
import System.Random (randomIO, StdGen, getStdGen, next, RandomGen)
import Control.Monad.Trans.Except(ExceptT(ExceptT),runExceptT,throwE)
import Foreign.C.Types (CInt(CInt))
import Control.Monad.IO.Class(liftIO)
import Foreign.C.String (newCString)


data Futhark_Context_Config
data Futhark_Context

data Futhark_u8_1d
data FutharkTestData
type ValuesType =  Ptr Futhark_Context
                -> Ptr Futhark_u8_1d -- Old fut array
                -> Ptr Word8         -- New array
                -> CInt

type ArbitraryType =  Ptr Futhark_Context
                   -> Ptr (Ptr FutharkTestData)
                   -> CInt               -- size
                   -> CInt               -- seed
                   -> CInt

type PropertyType =  Ptr Futhark_Context
                  -> Ptr Bool
                  -> Ptr FutharkTestData
                  -> CInt

type ShowType =  Ptr Futhark_Context
              -> Ptr (Ptr Futhark_u8_1d)
              -> Ptr FutharkTestData
              -> CInt

myDlsym :: DL.DL -> String -> IO (FunPtr f)
myDlsym dl fname = do
  eitherFun <- tryIOError $ DL.dlsym dl fname
  case eitherFun of
    Right fun -> return fun
    Left msg  -> error $ "Could not find symbol " ++ fname ++ "."

dlsymEither :: DL.DL -> String -> ExceptT IOError IO (FunPtr f)
dlsymEither dl fname = do
  ExceptT $ tryIOError $ DL.dlsym dl fname

foreign import ccall "dynamic"
  mkConfig :: FunPtr (IO (Ptr Futhark_Context_Config)) -> IO (Ptr Futhark_Context_Config)

newFutConfig :: DL.DL -> IO (Ptr Futhark_Context_Config)
newFutConfig dl = do
  funCfg <- DL.dlsym dl "futhark_context_config_new"
  cfg <- mkConfig funCfg
  return cfg

foreign import ccall "dynamic"
  mkConfigFree :: FunPtr (Ptr Futhark_Context_Config -> IO ()) -> Ptr Futhark_Context_Config -> IO ()
newFutFreeConfig :: DL.DL -> Ptr Futhark_Context_Config -> IO ()
newFutFreeConfig dl cfg = do
  f <- DL.dlsym dl "futhark_context_config_free"
  mkConfigFree f cfg

foreign import ccall "dynamic"
  mkNewFutContext :: FunPtr (Ptr Futhark_Context_Config
                  -> IO (Ptr Futhark_Context))
                  -> Ptr Futhark_Context_Config
                  -> IO (Ptr Futhark_Context)
newFutContext :: DL.DL -> Ptr Futhark_Context_Config -> IO (Ptr Futhark_Context)
newFutContext dl cfg = do
  ctx_fun <- DL.dlsym dl "futhark_context_new"
  mkNewFutContext ctx_fun cfg

foreign import ccall "dynamic"
  mkContextFree :: FunPtr (Ptr Futhark_Context -> IO ()) -> Ptr Futhark_Context -> IO ()
freeFutContext dl ctx = do
  f <- DL.dlsym dl "futhark_context_free"
  mkContextFree f ctx

foreign import ccall "dynamic"
  mkFutShape :: FunPtr (Ptr Futhark_Context -> Ptr Futhark_u8_1d -> Ptr CInt)
             ->         Ptr Futhark_Context -> Ptr Futhark_u8_1d -> Ptr CInt

futShape :: DL.DL -> IO (Ptr Futhark_Context -> Ptr Futhark_u8_1d -> CInt)
futShape dl = do
  f <- DL.dlsym dl "futhark_shape_u8_1d"
  return (\ctx futArr ->
    -- We're just reading local state,
    -- so I believe it's alright to
    -- perform IO unsafely
    unsafePerformIO $ peek $ mkFutShape f ctx futArr)

haskifyArr2 :: CInt -> (i -> Ptr Word8 -> CInt) -> i -> IO (Either CInt [Word8])
haskifyArr2 size c_fun input =
  allocaArray (fromIntegral size) $ (\outPtr -> do
    let exitcode = c_fun input outPtr
    if exitcode == 0
      then (return . Right) =<< peekArray (fromIntegral size) outPtr
      else return $ Left exitcode)

foreign import ccall "dynamic"
  mkFutValues :: FunPtr ValuesType -> ValuesType
mkValues :: DL.DL
         -> IO (  Ptr Futhark_Context
               -> Ptr Futhark_u8_1d
               -> Either CInt String)
mkValues dl = do
  shapeFun  <- futShape dl
  valuesFun <- mkFutValues <$> DL.dlsym dl "futhark_values_u8_1d"
  return (\ctx futArr -> unsafePerformIO $ do
             eitherArr <- haskifyArr2 (shapeFun ctx futArr) (valuesFun ctx) futArr
             case eitherArr of
               Right hsList -> do
                 return $ Right $ decode hsList
               Left errorcode -> return $ Left errorcode)

haskify3 :: Storable out
         => (Ptr Futhark_Context -> Ptr out -> input -> CInt)
         -> Ptr Futhark_Context
         -> input
         -> IO (Either CInt out)
haskify3 c_fun ctx input =
  alloca $ (\outPtr -> do
    let exitcode = c_fun ctx outPtr input
    if exitcode == 0
    then Right <$> peek outPtr
    else return $ Left exitcode)

haskify4 :: Storable out
         => (Ptr Futhark_Context -> Ptr out -> input1 -> input2 -> CInt)
         -> Ptr Futhark_Context
         -> input1
         -> input2
         -> IO (Either CInt out)
haskify4 c_fun ctx input1 input2 =
  alloca $ (\outPtr -> do
    let exitcode = c_fun ctx outPtr input1 input2
    if exitcode == 0
    then Right <$> peek outPtr
    else return $ Left exitcode)

foreign import ccall "dynamic"
  mkFutShow :: FunPtr ShowType -> ShowType
mkShow :: DL.DL
       -> Ptr Futhark_Context
       -> String
       -> ExceptT IOError IO (Ptr FutharkTestData -> Either CInt String)
mkShow dl ctx name = do
  showPtr   <- dlsymEither dl ("futhark_entry_" ++ name)
  futValues <- ExceptT $ return <$> mkValues dl
  return $ \input -> unsafePerformIO $ do
    eU8arr <- haskify3 (mkFutShow showPtr) ctx input
    case eU8arr of
      Right u8arr   -> return $ futValues ctx u8arr
      Left exitCode -> return $ Left exitCode

foreign import ccall "dynamic"
  mkFutArb :: FunPtr ArbitraryType -> ArbitraryType

mkArbitrary :: DL.DL
            -> Ptr Futhark_Context
            -> String
            -> IO (CInt -> CInt -> Either CInt (Ptr FutharkTestData))
mkArbitrary dl ctx name = do
  arbPtr <- myDlsym dl ("futhark_entry_" ++ name)
  return $ (\i1 i2 -> unsafePerformIO $ haskify4 (mkFutArb arbPtr) ctx i1 i2)

foreign import ccall "dynamic"
  mkFutProp :: FunPtr PropertyType -> PropertyType
mkProperty :: DL.DL -> Ptr Futhark_Context -> String -> IO (Ptr FutharkTestData -> Either CInt Bool)
mkProperty dl ctx name = do
  propPtr <- DL.dlsym dl ("futhark_entry_" ++ name)
  return $ \input -> unsafePerformIO $ haskify3 (mkFutProp propPtr) ctx input


uncurry3 f (a,b,c) = f a b c

spaces = ' ':spaces

indent n str =
  take n spaces ++ str

-- off by one?
padEndUntil end str = str ++ take (end - length str) spaces

formatMessages :: [(String, String)] -> [String]
formatMessages messages = lines
  where
    (names, values) = unzip messages
    namesColon      = (++ ": ") <$> names
    longestName     = foldl' (\acc elm -> max acc $ length elm) 0 namesColon
    formatName      = padEndUntil longestName
    formattedNames  = map formatName namesColon
    lines           = zipWith (++) formattedNames values

funCrash :: String -> [(String,String)] -> [String]
funCrash stage messages = crashMessage
  where
    restLines       = formatMessages messages
    crashMessage    = stage:(indent 2 <$> restLines)

crashMessage :: String -> CInt -> [(String,[(String,String)])] -> [String]
crashMessage name seed messages = crashMessage
  where
    crashLine = ("Property " ++ name ++ " crashed on seed " ++ show seed)
    lines                = uncurry funCrash =<< messages
    linesWithDescription = "in function(s)":(indent 2 <$> lines)
    crashMessage         = crashLine:(indent 2 <$> linesWithDescription)


data Stage = Arb | Test | Show
stage2str Arb  = "arbitrary"
stage2str Test = "property"
stage2str Show = "show"

data Result =
    Success
    { resultTestName :: String
    , numTests       :: Integer
    }
  | Failure
    { resultTestName :: String
    -- Nothing if no attempt at showing could be made
    -- Just Left if it tried to generate a string but failed
    -- Just Right if a string was successfully generated
    , shownInput     :: Maybe (Either CInt String)
    , resultSeed     :: CInt
    }
  | Exception
    { resultTestName :: String
    -- Nothing if no attempt at showing could be made
    -- Just Left if it tried to generate a string but failed
    -- Just Right if a string was successfully generated
    , shownInput     :: Maybe (Either CInt String)
    , errorStatge    :: Stage
    , futExitCode    :: CInt
    , resultSeed     :: CInt
    }

data State = MkState
  { stateTestName   :: String
  , arbitrary       :: CInt -> CInt -> Either CInt (Ptr FutharkTestData)
  , property        :: Ptr FutharkTestData -> Either CInt Bool
  , shower          :: Maybe (Ptr FutharkTestData -> Either CInt String)
  , maxSuccessTests :: Integer
  , numSuccessTests :: Integer
  , computeSize     :: Int -> CInt
  , randomSeed      :: StdGen
  }

data FutFunNames = FutFunNames
  { ffTestName :: String
  , arbName    :: String
  , propName   :: String
  , showName   :: String
  , arbFound   :: Bool
  , propFound  :: Bool
  , showFound  :: Bool
  }

newFutFunNames name = FutFunNames
  { ffTestName = name
  , arbName    = name ++ "arbitrary"
  , propName   = name ++ "property"
  , showName   = name ++ "show"
  , arbFound   = False
  , propFound  = False
  , showFound  = False
  }

data FutFuns = MkFuns
  { futArb  :: CInt -> CInt -> Either CInt (Ptr FutharkTestData)
  , futProp :: Ptr FutharkTestData -> Either CInt Bool
  , futShow :: Maybe (Ptr FutharkTestData -> Either CInt String)
  }


loadFutFuns dl ctx testName = do
  dynArb  <- mkArbitrary dl ctx $ testName ++ "arbitrary"
  dynProp <- mkProperty  dl ctx $ testName ++ "property"
  eitherDynShow <- runExceptT $  mkShow dl ctx $ testName ++ "show"
  let dynShow =
        case eitherDynShow of
          Right fun -> Just fun
          Left _    -> Nothing
  return MkFuns { futArb  = dynArb
                , futProp = dynProp
                , futShow = dynShow
                }

mkDefaultState :: String -> StdGen -> FutFuns -> State
mkDefaultState testName gen fs =
  MkState
  { stateTestName   = testName
  , arbitrary       = futArb fs
  , property        = futProp fs
  , shower          = futShow fs
  , maxSuccessTests = 100
  , computeSize     = toEnum . \n ->  n
    -- (maxSuccessTests state) - (maxSuccessTests state) `div` (n+1)
  , numSuccessTests = 0
  , randomSeed      = gen
  }

size :: State -> CInt
size state = (computeSize state (fromIntegral $ numSuccessTests state))

getSeed :: State -> CInt
getSeed = toEnum . fst . next . randomSeed

nextGen = snd . next . randomSeed

nextState :: State -> (CInt, State)
nextState state = (cInt, newState)
  where
    (int,newGen) = next $ randomSeed state
    cInt         = toEnum int
    newState     = state {randomSeed = newGen}

f *< a = f <*> pure a

someFun :: State -> IO Result
someFun state = do
  let seed = getSeed state
  case arbitrary state (size state) seed of
    Left arbExitCode -> return $ Exception (stateTestName state) Nothing Arb arbExitCode seed
    Right testdata ->
      case property state testdata of
        Left propExitCode ->
          return $ Exception (stateTestName state) (shower state *< testdata) Test propExitCode seed
        Right result ->
          if result
          then return Success {resultTestName = stateTestName state, numTests = numSuccessTests state}
          else
            return $ Failure { resultTestName = stateTestName state
                             , shownInput     = shower state *< testdata
                             , resultSeed     = seed
                             }

infResults :: State -> IO Result
infResults state
  | numSuccessTests state >= maxSuccessTests state = return $ Success
                                                     { resultTestName = stateTestName state
                                                     , numTests       = numSuccessTests state
                                                     }
  | otherwise = do
  result <- someFun state
  case result of
    Success _ _ -> infResults $ state { numSuccessTests = numSuccessTests state + 1
                                      , randomSeed      = nextGen state
                                      }
    _       -> return result

result2str :: Result -> String
result2str (Success name numTests) = "Property " ++ name ++ " holds after " ++ show numTests ++ " tests"
result2str (Failure name Nothing seed) =
  "Property " ++ name ++ " failed on seed " ++ show seed
result2str (Failure name (Just (Right str)) _) =
  "Property " ++ name ++ " failed on input " ++ str
result2str (Failure name (Just (Left exitCode)) seed) =
  unlines $ ("Property " ++ name ++ " failed on seed " ++ show seed)
  : crashMessage name seed [("show",[("Exit code", show exitCode)])]
result2str (Exception name Nothing stage exitCode seed) =
  unlines $ crashMessage name seed [((stage2str stage),[("Exit code", show exitCode)])]
result2str (Exception name (Just (Right input)) stage exitCode seed) =
  unlines $ crashMessage name seed [((stage2str stage), [ ("Input", input)
                                                        , ("Exit code", show exitCode)
                                                        ])]

result2str (Exception name (Just (Left showExitCode)) stage exitCode seed) =
  unlines $ crashMessage name seed [ ((stage2str stage),[("Exit code", show exitCode)])
                                   , ("show", [("Exit code", show showExitCode)])
                                   ]

getTestName ["--", "fucheck", name] = Just name
getTestName _                       = Nothing

mapPerhaps :: (a -> Maybe a) -> [a] -> [a]
mapPerhaps f l = foldr (\elm acc -> case f elm of ; Nothing -> elm:acc ; Just newElm -> newElm:acc) [] l

funNameMatches ("entry":actualName:_) expectedName = actualName == expectedName
funNameMatches _ _ = False

anyFunNameMatches line ffns =
  if matchesLine $ arbName ffns
  then Just $ ffns {arbFound = True}
  else if matchesLine $ propName ffns
       then Just $ ffns {propFound = True}
       else if matchesLine $ showName ffns
            then Just $ ffns {showFound = True}
            else Nothing
  where matchesLine = funNameMatches line


filterMap :: (a -> Maybe b) -> [a] -> [b]
filterMap f = foldr (\elm acc -> case f elm of
                          Just x  -> x:acc
                          Nothing -> acc) []
checkLine foundFuns line =
  case getTestName line of
    Just newName -> newFutFunNames newName : foundFuns
    Nothing      -> mapPerhaps (anyFunNameMatches line) foundFuns

findTests :: String -> [String]
findTests source = tests
  where
    tokens = words <$> lines source
    tests  = filterMap getTestName tokens --reverse $ foldl' checkLine [] tokens


--myReadProcess :: TP.ProcessConfig stdin stdoutIgnored stderrIgnored ->  ExceptT ExitCode IO (ByteString, ByteString)
--myReadProcess p = do
--  (exitCode, out, err) :: (ExitCode, ByteString, ByteString) <- return $ TP.readProcess p
--  case exitCode of
--    ExitSuccess -> return (out,err)
--    _           -> throwE exitCode

letThereBeDir dir = do
  dirExists <- doesDirectoryExist dir
  if not dirExists
    then createDirectory dir
    else return ()

headWithDefault def []     = def
headWithDefault _ (head:_) = head

right (Right a) = a

exitOnCompilationError exitCode filename =
  case exitCode of
    ExitSuccess -> return ()
    _           -> do
      putStrLn $ "Could not compile " ++ filename
      exitFailure

testIOprep dl ctx test = do
  gen <- getStdGen
  futFuns <- loadFutFuns dl ctx test
  return (test, gen,futFuns)


main :: IO ()
main = do
  args <- getArgs
  --case compare (length args) 1 of
  --  LT -> do
  --    putStrLn "Give test file as argument"
  --    exitSuccess
  --  GT -> do
  --    putStrLn "Only accepts one argument; the test file"
  --    exitSuccess
  --  EQ -> return ()

  let filename = headWithDefault "src/futs/fucheck" args
  let tmpDir = "/tmp/fucheck/"
  let tmpFile = tmpDir ++ "fucheck-tmp-file"

  fileText <- readFile $ filename ++ ".fut"
  let testNames = findTests fileText

  letThereBeDir tmpDir

  (futExitCode, futOut, futErr) <-
    TP.readProcess $ TP.proc "futhark" ["c", "--library", "-o", tmpFile, filename ++ ".fut"]
  exitOnCompilationError futExitCode $ filename ++ ".fut"

  (gccExitCode, gccOut, gccErr) <-
    TP.readProcess $ TP.proc "gcc" [tmpFile ++ ".c", "-o", tmpFile ++ ".so", "-fPIC", "-shared"]
  exitOnCompilationError gccExitCode $ "generated C file"

  dl <- DL.dlopen (tmpFile ++ ".so") [DL.RTLD_NOW] -- Read up on flags

  let firstTest = head testNames

  cfg <- newFutConfig dl
  ctx <- newFutContext dl cfg

  ioPrep <- sequence $ map (testIOprep dl ctx) testNames
  let states = map (uncurry3 mkDefaultState) ioPrep
  sequence_ $ map ((putStrLn . result2str) <=< infResults) states
  freeFutContext dl ctx
  newFutFreeConfig dl cfg
  DL.dlclose dl
