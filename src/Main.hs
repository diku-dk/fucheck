{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Codec.Binary.UTF8.String (decode)
import Data.ByteString (pack)
import Data.ByteString.UTF8 (toString)
import qualified Data.ByteString.UTF8 as U
import Data.Int  (Int32, Int64)
import Data.Word (Word8)
import Foreign.Ptr (Ptr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Storable (Storable, peek)
import Data.List (unfoldr, foldl')
import System.Random (randomIO, getStdGen, next, RandomGen)
import Control.Monad.Trans.Except(ExceptT(ExceptT),runExceptT)


data Futhark_Context_Config
foreign import ccall "futhark_context_config_new"
  futNewConfig:: IO (Ptr Futhark_Context_Config)

data Futhark_Context
foreign import ccall "futhark_context_new"
  futNewContext :: Ptr Futhark_Context_Config -> IO (Ptr Futhark_Context)

foreign import ccall "futhark_context_free"
  futFreeContext :: Ptr Futhark_Context -> IO ()

foreign import ccall "futhark_context_config_free"
  futFreeConfig :: Ptr Futhark_Context_Config -> IO ()

right (Right r) = r



type Cint = Int32
data Futhark_u8_1d
data FutharkTestData

haskify :: Storable out
        => (Ptr out -> input -> IO Cint)
        -> input
        -> ExceptT Cint IO out
haskify c_fun input =
  ExceptT $ alloca $ (\outPtr -> do
    exitcode <- c_fun outPtr input
    if exitcode == 0
    then (return . Right) =<< peek outPtr
    else return $ Left exitcode)

haskify2 :: Storable out
        => (Ptr out -> input1 -> input2 -> IO Cint)
        -> input1
        -> input2
        -> ExceptT Cint IO out
haskify2 c_fun input1 input2 =
  ExceptT $ alloca $ (\outPtr -> do
    exitcode <- c_fun outPtr input1 input2
    if exitcode == 0
    then (return . Right) =<< peek outPtr
    else return $ Left exitcode)

haskifyArr size c_fun input =
  ExceptT $ allocaArray size $ (\outPtr -> do
    exitcode <- c_fun input outPtr
    if exitcode == 0
    then (return . Right) =<< peekArray size outPtr
    else return $ Left exitcode)


-- New []u8
foreign import ccall "futhark_new_i8_1d"
  futNewArru8 :: Ptr Futhark_Context
              -> Ptr Word8              -- The old array
              -> Ptr Int64              -- The size
              -> IO (Ptr Futhark_u8_1d) -- The fut array

-- Move to C array
foreign import ccall
  futhark_values_u8_1d :: Ptr Futhark_Context
                       -> Ptr Futhark_u8_1d -- Old fut array
                       -> Ptr Word8         -- New array
                       -> IO Cint          -- Error info? Is this the right type?


futValues :: Ptr Futhark_Context -> Ptr Futhark_u8_1d -> ExceptT Cint IO String
futValues ctx futArr = ExceptT $ do
  shape <- futShape ctx futArr
  eitherArr <- runExceptT $ haskifyArr shape (futhark_values_u8_1d ctx) futArr
  case eitherArr of
    Right hsList -> do
      return $ Right $ decode hsList
    Left errorcode -> return $ Left errorcode


-- Get dimensions of fut array
foreign import ccall
  futhark_shape_u8_1d :: Ptr Futhark_Context
                      -> Ptr Futhark_u8_1d       -- Array.
                      -> IO (Ptr Int)            -- size

futShape :: Ptr Futhark_Context -> Ptr Futhark_u8_1d -> IO Int
futShape ctx futArr = do
  shapePtr <- futhark_shape_u8_1d ctx futArr
  peek shapePtr

-- Arbitrary
foreign import ccall
  futhark_entry_arbitrary :: Ptr Futhark_Context
                          -> Ptr futharkTestData
                          -> Cint               -- size
                          -> Cint               -- seed
                          -> IO Cint

futArbitrary :: Ptr Futhark_Context -> Cint -> Cint -> ExceptT Cint IO (Ptr futharkTestData)
futArbitrary ctx = haskify2 (futhark_entry_arbitrary ctx)


-- Property
foreign import ccall
  futhark_entry_property :: Ptr Futhark_Context
                         -> Ptr Bool
                         -> Ptr FutharkTestData
                         -> IO Cint

futProperty :: Ptr Futhark_Context -> Ptr FutharkTestData -> ExceptT Cint IO Bool
futProperty ctx = haskify (futhark_entry_property ctx)

-- Show
foreign import ccall
  futhark_entry_show :: Ptr Futhark_Context
                     -> Ptr (Ptr Futhark_u8_1d)
                     -> Ptr FutharkTestData
                     -> IO Cint


-- Use monad transformer?
futShow :: Ptr Futhark_Context -> Ptr FutharkTestData -> ExceptT Cint IO String
futShow ctx input = do
  u8arr <- haskify (futhark_entry_show ctx) input
  futValues ctx u8arr

--  eitheru8arr <- haskify futhark_entry_show ctx input
--  ExceptT $ case eitheru8arr of
--    Right u8arr -> do
--      str <- futValues ctx u8arr
--      return $ Right str
--    Left errorcode -> return $ Left errorcode


-- Entry
foreign import ccall
  futhark_entry_main :: Ptr Futhark_Context
                     -> Ptr Bool                -- succeeded?
                     -> Ptr (Ptr Futhark_u8_1d) -- string
                     -> Cint                   -- seed
                     -> IO (Cint)              -- Possibly error msg?

--futValues :: Ptr Futhark_Context -> Ptr Futhark_u8_1d -> ExceptT Cint IO String

--futEntry :: Ptr Futhark_Context -> Cint -> ExceptT Result IO String
--futEntry ctx seed = do
--  alloca $ (\boolPtr -> do
--    entryResult <-
--      alloca $ (\strPtr -> do
--        exitCode <- futhark_entry_main ctx boolPtr strPtr seed
--        if exitCode == 0
--        then (return . Right) =<< peek strPtr
--        else return $ Left exitCode
--        )
--
--    case entryResult of
--      Left exitCode -> return $ Exception Test exitCode seed
--      Right str -> do
--        bool <- peek boolPtr
--        eStr <- runExceptT $ futValues ctx str
--        return $ if bool then Success else Failure eStr seed)


spaces = ' ':spaces

indent n str =
  take n spaces ++ str

-- off by one?
padEndUntil end str = str ++ take (end - length str) spaces

--tree n node subnodes =
--  node ++ "\n" ++ (indent n <$> subnodes)

formatMessages :: [(String, String)] -> [String]
formatMessages messages = lines
  where
    (names, values) = unzip messages
    longestName     = foldl' (\acc elm -> max acc $ length elm) 0 names
    formatName      = padEndUntil longestName . (++ ":")
    formattedNames  = map formatName names
    lines           = zipWith (++) formattedNames values

funCrash :: String -> [(String,String)] -> [String]
funCrash stage messages = crashMessage
  where
    restLines       = formatMessages messages
    crashMessage    = stage:(indent 2 <$> restLines)

crashMessage :: Cint -> [(String,[(String,String)])] -> [String]
crashMessage seed messages = crashMessage
  where
    crashLine = ("Futhark crashed on seed " ++ show seed)
                : [indent 2 "in function(s)"]
    lines = uncurry funCrash =<< messages
    crashMessage = crashLine ++ (indent 2 <$> lines)




data Stage = Arb | Test | Show
stage2str Arb  = "arbitrary"
stage2str Test = "property"
stage2str Show = "show"

data Result = Success
            | Failure (Either Cint String) Cint               -- input, seed
            | Exception (Either Cint String) Stage Cint Cint -- input, stage, error code, seed

someFun :: Ptr Futhark_Context -> Cint -> Cint -> IO Result
someFun ctx size seed = do
  eTestdata <- runExceptT $ futArbitrary ctx size seed
  case eTestdata of
    Left arbExitCode -> return $ Exception (Right "someerrorstring") Arb arbExitCode seed -- ARGH!
    Right testdata -> do
      eResult <- runExceptT $ futProperty ctx testdata
      case eResult of
        Left propExitCode -> return $ Exception (Right "Yabbadabbadoo!") Test propExitCode seed
        Right result ->
          if result
          then return Success
          else do
            eStrInput <- runExceptT $ futShow ctx testdata
            return $ Failure eStrInput seed

result2str :: Result -> String
result2str Success = "Success!"
result2str (Failure (Right str) seed) =
  "Test failed on input " ++ str
result2str (Failure (Left exitCode) seed) =
  unlines $ ("Test failed on seed " ++ show seed)
  : crashMessage seed [("show",[("Exit code", show exitCode)])]
result2str (Exception _ stage exitCode seed) = -- CHANGE _
  unlines $ crashMessage seed [((stage2str stage),[("Exit code", show exitCode)])]





main :: IO ()
main = do
  cfg <- futNewConfig
  ctx <- futNewContext cfg

  gen <- getStdGen

  arb <- runExceptT $ futArbitrary ctx 20 653275648
  res <- runExceptT $ futProperty ctx $ right arb
  str <- runExceptT $ futShow ctx $ right arb

  putStrLn $ show $ right res
  putStrLn $ right str

  result <- someFun ctx 20 653275648 -- $ toEnum $ fst $ next gen
  putStrLn $ result2str result


--  let tests = testLoop ctx gen
--  result <- doTests 100 tests
--
--  case result of
--    Success -> putStrLn "Success"
--    Failure futStr seed -> do
--      putStrLn $ "Failure with input " ++ (right futStr) ++ " from seed " ++ show seed
--    Exception _ exitCode seed -> putStrLn ("Futhark crashed with exit code " ++ show exitCode ++ " from seed " ++ show seed)

  futFreeContext ctx
  futFreeConfig cfg

--coalesce Success Success = Success
--coalesce Success failure = failure
--coalesce failure _       = failure
--
--doTests :: Int -> [IO Result] -> IO Result
--doTests n ios = do
--  results <- sequence $ take n ios
--  return $ foldl' coalesce Success results
--
--testLoop :: RandomGen g => Ptr Futhark_Context -> g -> [IO Result]
--testLoop ctx gen = results
--  where
--    seeds      = myIterate next32 gen
--    results = map (futEntry ctx) seeds
--
--next32 :: RandomGen g => g -> (Cint, g)
--next32 g = (toEnum int, newGen)
--  where (int,newGen) = next g
--
--myIterate :: (a -> (b,a)) -> a -> [b]
--myIterate f x = unfoldr (\x -> Just $ f x) x
