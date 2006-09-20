-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) 2006 Duncan Coutts
-- License     :  BSD-style
--
-- Maintainer  :  duncan.coutts@worc.ox.ac.uk
-- Stability   :  experimental
-- Portability :  portable (H98 + FFI)
--
-- Zlib wrapper layer
--
-----------------------------------------------------------------------------
module Codec.Compression.Zlib.Stream (
  
  -- * The Zlib state monad
  Stream,
  run,
  unsafeInterleave,
  unsafeLiftIO,
  
  -- * Initialisation
  deflateInit, 
  inflateInit,
  
  -- ** Initialisation parameters
  Format(..),
  CompressionLevel(..),
  Method(..),
  WindowBits(..),
  MemoryLevel(..),
  CompressionStrategy(..),

  -- * The buisness
  deflate,
  inflate,
  Status(..),
  Flush(..),

  -- * Buffer management
  -- ** Input buffer
  pushInputBuffer,
  inputBufferEmpty,

  -- ** Output buffer
  pushOutputBuffer,
  popOutputBuffer,
  outputBufferBytesAvailable,
  outputBufferSpaceRemaining,
  outputBufferFull,

  -- * Debugging
  consistencyCheck,
  dump,
  trace,
  
  ) where

import Foreign
import Foreign.C
import Data.ByteString.Base
import System.IO.Unsafe (unsafeInterleaveIO)
import Control.Monad (liftM)
import Control.Exception (assert)

import Prelude hiding (length)

#include <zlib.h>


pushInputBuffer :: ForeignPtr Word8 -> Int -> Int -> Stream ()
pushInputBuffer inBuf' offset length = do

  -- must not push a new input buffer if the last one is not used up
  inAvail <- getInAvail
  assert (inAvail == 0) $ return ()

  -- Now that we're setting a new input buffer, we can be sure that zlib no
  -- longer has a reference to the old one. Therefore this is the last point
  -- at which the old buffer had to be retained. It's safe to release now.
  inBuf <- getInBuf 
  unsafeLiftIO $ touchForeignPtr inBuf    
 
  -- now set the available input buffer ptr and length
  setInBuf   inBuf'
  setInAvail length
  setInNext  (unsafeForeignPtrToPtr inBuf' `plusPtr` offset)
  -- Note the 'unsafe'. We are passing the raw ptr inside inBuf' to zlib.
  -- To make this safe we need to hold on to the ForeignPtr for at least as
  -- long as zlib is using the underlying raw ptr.


inputBufferEmpty :: Stream Bool
inputBufferEmpty = getInAvail >>= return . (==0)


pushOutputBuffer :: ForeignPtr Word8 -> Int -> Int -> Stream ()
pushOutputBuffer outBuf' offset length = do

  --must not push a new buffer if there is still data in the old one
  outAvail <- getOutAvail
  assert (outAvail == 0) $ return ()
  -- Note that there may still be free space in the output buffer, that's ok,
  -- you might not want to bother completely filling the output buffer say if
  -- there's only a few free bytes left.

  outBuf <- getOutBuf
  unsafeLiftIO $ touchForeignPtr outBuf
    
  -- now set the available input buffer ptr and length
  setOutBuf  outBuf'
  setOutFree length
  setOutNext (unsafeForeignPtrToPtr outBuf' `plusPtr` offset)

  setOutOffset offset
  setOutAvail  0


-- get that part of the output buffer that is currently full
-- (might be 0, use outputBufferBytesAvailable to check)
-- this may leave some space remaining in the buffer, use
-- outputBufferSpaceRemaining to check.
popOutputBuffer :: Stream (ForeignPtr Word8, Int, Int)
popOutputBuffer = do

  outBuf    <- getOutBuf
  outOffset <- getOutOffset
  outAvail  <- getOutAvail

  -- there really should be something to pop, otherwise it's silly
  assert (outAvail > 0) $ return ()
  
  setOutOffset (outOffset + outAvail)
  setOutAvail  0
  
  return (outBuf, outOffset, outAvail)


-- this is the number of bytes available in the output buffer
outputBufferBytesAvailable :: Stream Int
outputBufferBytesAvailable = getOutAvail


-- you needen't get all the output immediately, you can continue until
-- there is no more output space available, this tells you that amount
outputBufferSpaceRemaining :: Stream Int
outputBufferSpaceRemaining = getOutFree


-- you only need to supply a new buffer when there is no more output buffer
-- space remaining
outputBufferFull :: Stream Bool
outputBufferFull = getOutFree >>= return . (==0)


-- you can only run this when the output buffer is not empty
-- you can run it when the input buffer is empty but it doesn't do anything
-- after running deflate either the output buffer will be full
-- or the input buffer will be empty (or both)
deflate :: Flush -> Stream Status
deflate flush = do

  outFree <- getOutFree 

  -- deflate needs free space in the output buffer
  assert (outFree > 0) $ return ()

  result <- deflate_ flush
  outFree' <- getOutFree
    
  -- number of bytes of extra output there is available as a result of
  -- the call to deflate:
  let outExtra = outFree - outFree'
  
  outAvail <- getOutAvail
  setOutAvail (outAvail + outExtra)
  return result


inflate :: Flush -> Stream Status
inflate flush = do

  outFree <- getOutFree 

  -- inflate needs free space in the output buffer
  assert (outFree > 0) $ return ()

  result <- inflate_ flush
  outFree' <- getOutFree
    
  -- number of bytes of extra output there is available as a result of
  -- the call to inflate:
  let outExtra = outFree - outFree'

  outAvail <- getOutAvail
  setOutAvail (outAvail + outExtra)
  return result


----------------------------
-- Stream monad
--

newtype Stream a = Z {
    unZ :: ForeignPtr StreamState
        -> ForeignPtr Word8
        -> ForeignPtr Word8
        -> Int -> Int
        -> IO (ForeignPtr Word8
              ,ForeignPtr Word8
              ,Int, Int, a)
  }

instance Monad Stream where
  (>>=)  = thenZ
--  m >>= f = (m `thenZ` \a -> consistencyCheck `thenZ_` returnZ a) `thenZ` f
  (>>)   = thenZ_
  return = returnZ
  fail   = failZ

returnZ :: a -> Stream a
returnZ a = Z $ \_ inBuf outBuf outOffset outLength ->
                  return (inBuf, outBuf, outOffset, outLength, a)
{-# INLINE returnZ #-}

thenZ :: Stream a -> (a -> Stream b) -> Stream b
thenZ (Z m) f =
  Z $ \stream inBuf outBuf outOffset outLength ->
    m stream inBuf outBuf outOffset outLength >>=
      \(inBuf', outBuf', outOffset', outLength', a) ->
        unZ (f a) stream inBuf' outBuf' outOffset' outLength'
{-# INLINE thenZ #-}

thenZ_ :: Stream a -> Stream b -> Stream b
thenZ_ (Z m) f =
  Z $ \stream inBuf outBuf outOffset outLength ->
    m stream inBuf outBuf outOffset outLength >>=
      \(inBuf', outBuf', outOffset', outLength', _) ->
        unZ f stream inBuf' outBuf' outOffset' outLength'
{-# INLINE thenZ_ #-}

failZ :: String -> Stream a
failZ msg = Z (\_ _ _ _ _ -> fail ("Codec.Compression.Zlib: " ++ msg))

{-# NOINLINE run #-}
run :: Stream a -> a
run (Z m) = unsafePerformIO $ do
  ptr <- mallocBytes (#{const sizeof(z_stream)})
  #{poke z_stream, zalloc}    ptr nullPtr
  #{poke z_stream, zfree}     ptr nullPtr
  #{poke z_stream, opaque}    ptr nullPtr
  #{poke z_stream, next_in}   ptr nullPtr
  #{poke z_stream, next_out}  ptr nullPtr
  #{poke z_stream, avail_in}  ptr (0 :: CUInt)
  #{poke z_stream, avail_out} ptr (0 :: CUInt)
  stream <- newForeignPtr_ ptr
  (_,_,_,_,a) <- m stream nullForeignPtr nullForeignPtr 0 0
  return a

unsafeLiftIO :: IO a -> Stream a
unsafeLiftIO m = Z $ \_stream inBuf outBuf outOffset outLength -> do
  a <- m
  return (inBuf, outBuf, outOffset, outLength, a)

-- It's unsafe because we discard the values here, so if you mutate anything
-- between running this and forcing the result then you'll get an inconsistent
-- stream state.
unsafeInterleave :: Stream a -> Stream a
unsafeInterleave (Z m) = Z $ \stream inBuf outBuf outOffset outLength -> do
  res <- unsafeInterleaveIO (m stream inBuf outBuf outOffset outLength)
  let select (_,_,_,_,a) = a
  return (inBuf, outBuf, outOffset, outLength, select res)

getStreamState :: Stream (ForeignPtr StreamState)
getStreamState = Z $ \stream inBuf outBuf outOffset outLength -> do
  return (inBuf, outBuf, outOffset, outLength, stream)

getInBuf :: Stream (ForeignPtr Word8)
getInBuf = Z $ \_stream inBuf outBuf outOffset outLength -> do
  return (inBuf, outBuf, outOffset, outLength, inBuf)

getOutBuf :: Stream (ForeignPtr Word8)
getOutBuf = Z $ \_stream inBuf outBuf outOffset outLength -> do
  return (inBuf, outBuf, outOffset, outLength, outBuf)

getOutOffset :: Stream Int
getOutOffset = Z $ \_stream inBuf outBuf outOffset outLength -> do
  return (inBuf, outBuf, outOffset, outLength, outOffset)

getOutAvail :: Stream Int
getOutAvail = Z $ \_stream inBuf outBuf outOffset outLength -> do
  return (inBuf, outBuf, outOffset, outLength, outLength)

setInBuf :: ForeignPtr Word8 -> Stream ()
setInBuf inBuf = Z $ \_stream _ outBuf outOffset outLength -> do
  return (inBuf, outBuf, outOffset, outLength, ())

setOutBuf :: ForeignPtr Word8 -> Stream ()
setOutBuf outBuf = Z $ \_stream inBuf _ outOffset outLength -> do
  return (inBuf, outBuf, outOffset, outLength, ())

setOutOffset :: Int -> Stream ()
setOutOffset outOffset = Z $ \_stream inBuf outBuf _ outLength -> do
  return (inBuf, outBuf, outOffset, outLength, ())

setOutAvail :: Int -> Stream ()
setOutAvail outLength = Z $ \_stream inBuf outBuf outOffset _ -> do
  return (inBuf, outBuf, outOffset, outLength, ())

----------------------------
-- Debug stuff
--

trace :: String -> Stream ()
trace = unsafeLiftIO . putStrLn 

dump :: Stream ()
dump = do
  inNext  <- getInNext
  inAvail <- getInAvail

  outNext <- getOutNext
  outFree <- getOutFree
  outAvail <- getOutAvail
  outOffset <- getOutOffset
  
  unsafeLiftIO $ putStrLn $
    "Stream {\n" ++
    "  inNext    = " ++ show inNext    ++ ",\n" ++
    "  inAvail   = " ++ show inAvail   ++ ",\n" ++
    "\n" ++
    "  outNext   = " ++ show outNext   ++ ",\n" ++
    "  outFree   = " ++ show outFree   ++ ",\n" ++
    "  outAvail  = " ++ show outAvail  ++ ",\n" ++
    "  outOffset = " ++ show outOffset ++ "\n"  ++
    "}"

  consistencyCheck

consistencyCheck :: Stream ()
consistencyCheck = do

  outBuf    <- getOutBuf
  outOffset <- getOutOffset
  outAvail  <- getOutAvail
  outNext   <- getOutNext

  let outBufPtr = unsafeForeignPtrToPtr outBuf

  assert (outBufPtr `plusPtr` (outOffset + outAvail) == outNext) $ return ()


----------------------------
-- zlib wrapper layer
--

data Status =
    Ok
  | StreamEnd
  | NeedDict
  | BufferError -- ^ No progress was possible or there was not enough room in
                --   the output buffer when 'Finish' is used. Note that
                --   'BuferError' is not fatal, and 'inflate' can be called
                --   again with more input and more output space to continue.

instance Enum Status where
  toEnum (#{const Z_OK})         = Ok
  toEnum (#{const Z_STREAM_END}) = StreamEnd
  toEnum (#{const Z_NEED_DICT})  = NeedDict
  toEnum (#{const Z_BUF_ERROR})  = BufferError
  toEnum other = error ("unexpected zlib status: " ++ show other)

isFatalError :: CInt -> Bool
isFatalError n | n >= 0             = False
isFatalError (#{const Z_BUF_ERROR}) = False
isFatalError _                      = True

throwError :: Stream a
throwError = do
  msg <- withStreamPtr (#{peek z_stream, msg})
  msg' <- unsafeLiftIO (peekCString msg)
  fail msg'

data Flush =
    NoFlush
  | SyncFlush
  | FullFlush
  | Finish
  | Block

instance Enum Flush where
  fromEnum NoFlush   = #{const Z_NO_FLUSH}
  fromEnum SyncFlush = #{const Z_SYNC_FLUSH}
  fromEnum FullFlush = #{const Z_FULL_FLUSH}
  fromEnum Finish    = #{const Z_FINISH}
  fromEnum Block     = #{const Z_BLOCK}

data Format =
    GZip       -- ^ Encode or decode with the gzip header format.
  | Zlib       -- ^ Encode or decode with the zlib header format.
  | Raw        -- ^ Encode or decode a raw data stream without any header.
  | GZipOrZlib -- ^ Enable zlib or gzip decoding with automatic header
               --   detection. This only makes sense for decompression.

-- | The compression method
data Method = Deflated -- ^ \'Deflate\' is the only one supported in this
                       -- version of zlib.

instance Enum Method where
  fromEnum Deflated = #{const Z_DEFLATED}

-- | Control amount of compression. This is a trade-off between the amount
-- of compression and the time and memory required to do the compression.
data CompressionLevel = 
    DefaultCompression   -- ^ The default compression level is 6 (that is, 
                         --   biased towards high compression at expense of speed).
  | NoCompression        -- ^ No compression, just a block copy.
  | BestSpeed            -- ^ The fastest compression method (less compression) 
  | BestCompression      -- ^ The slowest compression method (best compression).
  | CompressionLevel Int -- ^ A specific compression level between 1 and 9.

instance Enum CompressionLevel where
  fromEnum DefaultCompression = -1
  fromEnum NoCompression      = 0
  fromEnum BestSpeed          = 1
  fromEnum BestCompression    = 9
  fromEnum (CompressionLevel n)
           | n >= 1 && n <= 9 = n
           | otherwise        = error "CompressLevel must be in the range 1..9"

data WindowBits = DefaultWindowBits
                | WindowBits Int

windowBits :: Format -> WindowBits-> Int
windowBits format bits = (formatModifier format) (checkWindowBits bits)
  where checkWindowBits DefaultWindowBits = 15
        checkWindowBits (WindowBits n)
          | n >= 8 && n <= 15 = n
          | otherwise         = error "WindowBits must be in the range 8..15"
        formatModifier Zlib       = id
        formatModifier GZip       = (+16)
        formatModifier GZipOrZlib = (+32)
        formatModifier Raw        = negate

-- | The 'MemoryLevel' parameter specifies how much memory should be allocated
-- for the internal compression state.
--
data MemoryLevel =
    DefaultMemoryLevel -- ^ The default. (Equivalent to @'MemoryLevel' 8@)
  | MinMemoryLevel     -- ^ Use minimum memory. This is slow and reduces the
                       --   compression ratio. (Equivalent to @'MemoryLevel' 1@)
  | MaxMemoryLevel     -- ^ Use maximum memory for optimal compression speed.
                       --   (Equivalent to @'MemoryLevel' 9@)
  | MemoryLevel Int    -- ^ Use a specific level in the range 1..9

instance Enum MemoryLevel where
  fromEnum DefaultMemoryLevel = 8
  fromEnum MinMemoryLevel     = 1
  fromEnum MaxMemoryLevel     = 9
  fromEnum (MemoryLevel n)
           | n >= 1 && n <= 9 = n
           | otherwise        = error "MemoryLevel must be in the range 1..9"
  

-- | The strategy parameter is used to tune the compression algorithm.
--
-- The strategy parameter only affects the compression ratio but not the
-- correctness of the compressed output even if it is not set appropriately.
--
data CompressionStrategy =
    DefaultStrategy -- ^ Use the 'DefaultStrategy' for normal data.
  | Filtered        -- ^ Use 'Filtered' for data produced by a filter (or
                    --   predictor). Filtered data consists mostly of small
                    --   values with a somewhat random distribution. In this
                    --   case, the compression algorithm is tuned to compress
                    --   them better. The effect of Z_FILTERED is to force more
                    --   Huffman coding and less string matching; it is
                    --   somewhat intermediate between 'DefaultStrategy' and
                    --   'HuffmanOnly'. 
  | HuffmanOnly     -- ^ Use 'HuffmanOnly' to force Huffman encoding only (no
                    --   string match). 
  | RLE             -- ^ Use 'RLE' to limit match distances to one (run-length
                    --   encoding). 'RLE' is designed to be almost as fast as
                    --   'HuffmanOnly', but give better compression for PNG
                    --   image data.
  | Fixed           -- ^ 'Fixed' prevents the use of dynamic Huffman codes,
                    --   allowing for a simpler decoder for special applications.

instance Enum CompressionStrategy where
  fromEnum DefaultStrategy = #{const Z_DEFAULT_STRATEGY}
  fromEnum Filtered        = #{const Z_FILTERED}
  fromEnum HuffmanOnly     = #{const Z_HUFFMAN_ONLY}
  fromEnum RLE             = #{const Z_RLE}
  fromEnum Fixed           = #{const Z_FIXED}

withStreamPtr :: (Ptr StreamState -> IO a) -> Stream a
withStreamPtr f = do
  stream <- getStreamState
  unsafeLiftIO (withForeignPtr stream f)

setInAvail :: Int -> Stream ()
setInAvail val = withStreamPtr $ \ptr ->
  #{poke z_stream, avail_in} ptr (fromIntegral val :: CUInt)

getInAvail :: Stream Int
getInAvail = liftM (fromIntegral :: CUInt -> Int) $
  withStreamPtr (#{peek z_stream, avail_in})

setInNext :: Ptr Word8 -> Stream ()
setInNext val = withStreamPtr (\ptr -> #{poke z_stream, next_in} ptr val)

getInNext :: Stream (Ptr Word8)
getInNext = withStreamPtr (#{peek z_stream, next_in})

setOutFree :: Int -> Stream ()
setOutFree val = withStreamPtr $ \ptr ->
  #{poke z_stream, avail_out} ptr (fromIntegral val :: CUInt)

getOutFree :: Stream Int
getOutFree = liftM (fromIntegral :: CUInt -> Int) $
  withStreamPtr (#{peek z_stream, avail_out})

setOutNext  :: Ptr Word8 -> Stream ()
setOutNext val = withStreamPtr (\ptr -> #{poke z_stream, next_out} ptr val)

getOutNext :: Stream (Ptr Word8)
getOutNext = withStreamPtr (#{peek z_stream, next_out})

inflateInit :: Format -> WindowBits -> Stream ()
inflateInit format bits = do
  err <- withStreamPtr $ \ptr ->
    c_inflateInit2 ptr (fromIntegral (windowBits format bits))
  if isFatalError err
    then throwError
    else do stream <- getStreamState
            unsafeLiftIO $ addForeignPtrFinalizer c_inflateEnd stream

deflateInit :: Format
            -> CompressionLevel
            -> Method
            -> WindowBits
            -> MemoryLevel
            -> CompressionStrategy
            -> Stream ()
deflateInit format compLevel method bits memLevel strategy = do
  err <- withStreamPtr $ \ptr ->
    c_deflateInit2 ptr
                  (fromIntegral (fromEnum compLevel))
                  (fromIntegral (fromEnum method))
                  (fromIntegral (windowBits format bits))
                  (fromIntegral (fromEnum memLevel))
                  (fromIntegral (fromEnum strategy))
  if isFatalError err
    then throwError
    else do stream <- getStreamState
            unsafeLiftIO $ addForeignPtrFinalizer c_deflateEnd stream

inflate_ :: Flush -> Stream Status
inflate_ flush = do
  err <- withStreamPtr (\ptr -> c_inflate ptr (fromIntegral (fromEnum flush)))
  if isFatalError err
    then do
      getStreamState >>= unsafeLiftIO . finalizeForeignPtr
      throwError
    else return (toEnum (fromIntegral err))

deflate_ :: Flush -> Stream Status
deflate_ flush = do
  err <- withStreamPtr (\ptr -> c_deflate ptr (fromIntegral (fromEnum flush)))
  if isFatalError err
    then do
      getStreamState >>= unsafeLiftIO . finalizeForeignPtr
      throwError
    else return (toEnum (fromIntegral err))

----------------------
-- The foreign imports

data StreamState = StreamState ()

foreign import ccall unsafe "zlib.h inflateInit2"
  c_inflateInit2 :: Ptr StreamState -> CInt -> IO CInt

foreign import ccall unsafe "zlib.h inflate"
  c_inflate :: Ptr StreamState -> CInt -> IO CInt

foreign import ccall unsafe "zlib.h &inflateEnd"
  c_inflateEnd :: FinalizerPtr StreamState


foreign import ccall unsafe "zlib.h deflateInit2"
  c_deflateInit2 :: Ptr StreamState
                 -> CInt -> CInt -> CInt -> CInt -> CInt -> IO CInt

foreign import ccall unsafe "zlib.h deflate"
  c_deflate :: Ptr StreamState -> CInt -> IO CInt

foreign import ccall unsafe "zlib.h &deflateEnd"
  c_deflateEnd :: FinalizerPtr StreamState