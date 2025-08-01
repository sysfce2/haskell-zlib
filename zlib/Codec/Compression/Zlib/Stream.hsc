{-# LANGUAGE CPP, ForeignFunctionInterface #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE CApiFFI #-}
-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) 2006-2015 Duncan Coutts
-- License     :  BSD-style
--
-- Maintainer  :  duncan@community.haskell.org
--
-- Zlib wrapper layer
--
-----------------------------------------------------------------------------
module Codec.Compression.Zlib.Stream (

  -- * The Zlib state monad
  Stream,
  State,
  mkState,
  runStream,
  unsafeLiftIO,
  finalise,

  -- * Initialisation
  deflateInit, 
  inflateInit,

  -- ** Initialisation parameters
  Format,
    gzipFormat,
    zlibFormat,
    rawFormat,
    gzipOrZlibFormat,
    formatSupportsDictionary,
  CompressionLevel(..),
    defaultCompression,
    noCompression,
    bestSpeed,
    bestCompression,
    compressionLevel,
  Method,
    deflateMethod,
  WindowBits(..),
    defaultWindowBits,
    windowBits,
  MemoryLevel(..),
    defaultMemoryLevel,
    minMemoryLevel,
    maxMemoryLevel,
    memoryLevel,
  CompressionStrategy,
    defaultStrategy,
    filteredStrategy,
    huffmanOnlyStrategy,
    rleStrategy,
    fixedStrategy,

  -- * The business
  deflate,
  inflate,
  Status(..),
  Flush(..),
  ErrorCode(..),
  -- ** Special operations
  inflateReset,

  -- * Buffer management
  -- ** Input buffer
  pushInputBuffer,
  inputBufferEmpty,
  popRemainingInputBuffer,

  -- ** Output buffer
  pushOutputBuffer,
  popOutputBuffer,
  outputBufferBytesAvailable,
  outputBufferSpaceRemaining,
  outputBufferFull,

  -- ** Dictionary
  deflateSetDictionary,
  inflateSetDictionary,

  -- ** Dictionary hashes
  DictionaryHash,
  dictionaryHash,
  zeroDictionaryHash,

#ifdef DEBUG
  -- * Debugging
  consistencyCheck,
  dump,
  trace,
#endif

  ) where

import Foreign
         ( Word8, Ptr, nullPtr, plusPtr, castPtr, peekByteOff, pokeByteOff
         , ForeignPtr, FinalizerPtr, mallocForeignPtrBytes, addForeignPtrFinalizer
         , withForeignPtr, touchForeignPtr, minusPtr )
import Foreign.ForeignPtr.Unsafe ( unsafeForeignPtrToPtr )
import System.IO.Unsafe          ( unsafePerformIO )
import Foreign
         ( finalizeForeignPtr )
import Foreign.C
#if MIN_VERSION_base(4,18,0)
import Foreign.C.ConstPtr
#endif
import Data.ByteString.Internal (nullForeignPtr)
import qualified Data.ByteString.Unsafe as B
import Data.ByteString (ByteString)
import Control.Applicative (Applicative(..))
import Control.Monad (ap,liftM)
#if MIN_VERSION_base(4,9,0)
import qualified Control.Monad.Fail as Fail
#endif
import Control.Monad.ST.Strict
import Control.Monad.ST.Unsafe
import Control.Exception (assert)
import Data.Bits (toIntegralSized)
import Data.Coerce (coerce)
import Data.Maybe (fromMaybe)
import GHC.Generics (Generic)
#ifdef DEBUG
import System.IO (hPutStrLn, stderr)
#endif

import Prelude hiding (length, Applicative(..))

#include "zlib.h"


pushInputBuffer :: ForeignPtr Word8 -> Int -> CUInt -> Stream ()
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


popRemainingInputBuffer :: Stream (ForeignPtr Word8, Int, Int)
popRemainingInputBuffer = do

  inBuf    <- getInBuf
  inNext   <- getInNext
  inAvail  <- getInAvail

  -- there really should be something to pop, otherwise it's silly
  assert (inAvail > 0) $ return ()
  setInAvail 0

  return (inBuf, inNext `minusPtr` unsafeForeignPtrToPtr inBuf, inAvail)


pushOutputBuffer :: ForeignPtr Word8 -> Int -> CUInt -> Stream ()
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


-- you needn't get all the output immediately, you can continue until
-- there is no more output space available, this tells you that amount
outputBufferSpaceRemaining :: Stream Int
outputBufferSpaceRemaining = getOutFree


-- you only need to supply a new buffer when there is no more output buffer
-- space remaining
outputBufferFull :: Stream Bool
outputBufferFull = liftM (==0) outputBufferSpaceRemaining


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


inflateReset :: Stream ()
inflateReset = do

  outAvail <- getOutAvail
  inAvail  <- getInAvail
  -- At the point where this is used, all the output should have been consumed
  -- and any trailing input should be extracted and resupplied explicitly, not
  -- just left.
  assert (outAvail == 0 && inAvail == 0) $ return ()

  err <- withStreamState $ \zstream ->
    c_inflateReset zstream
  failIfError err


-- | Dictionary length must fit into t'CUInt'.
deflateSetDictionary :: ByteString -> Stream Status
deflateSetDictionary dict = do
  err <- withStreamState $ \zstream ->
           B.unsafeUseAsCStringLen dict $ \(ptr, len) ->
             c_deflateSetDictionary zstream (castPtr ptr) (int2cuint len)
  toStatus err

-- | Dictionary length must fit into t'CUInt'.
inflateSetDictionary :: ByteString -> Stream Status
inflateSetDictionary dict = do
  err <- withStreamState $ \zstream -> do
           B.unsafeUseAsCStringLen dict $ \(ptr, len) ->
             c_inflateSetDictionary zstream (castPtr ptr) (int2cuint len)
  toStatus err

-- | A hash of a custom compression dictionary. These hashes are used by
-- zlib as dictionary identifiers.
-- (The particular hash function used is Adler32.)
--
newtype DictionaryHash = DictHash CULong
  deriving (Eq, Ord, Read, Show)

-- | Update a running 'DictionaryHash'. You can generate a 'DictionaryHash'
-- from one or more 'ByteString's by starting from 'zeroDictionaryHash', e.g.
--
-- > dictionaryHash zeroDictionaryHash :: ByteString -> DictionaryHash
--
-- or
--
-- > foldl' dictionaryHash zeroDictionaryHash :: [ByteString] -> DictionaryHash
--
-- Dictionary length must fit into t'CUInt'.
dictionaryHash :: DictionaryHash -> ByteString -> DictionaryHash
dictionaryHash (DictHash adler) dict =
  unsafePerformIO $
    B.unsafeUseAsCStringLen dict $ \(ptr, len) ->
      liftM DictHash $ c_adler32 adler (castPtr ptr) (int2cuint len)

-- | A zero 'DictionaryHash' to use as the initial value with 'dictionaryHash'.
--
zeroDictionaryHash :: DictionaryHash
zeroDictionaryHash = DictHash 0

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

instance Functor Stream where
  fmap   = liftM

instance Applicative Stream where
  pure   = returnZ
  (<*>)  = ap
  (*>)   = thenZ_

instance Monad Stream where
  (>>=)  = thenZ
--  m >>= f = (m `thenZ` \a -> consistencyCheck `thenZ_` returnZ a) `thenZ` f
  (>>)   = (*>)

#if !MIN_VERSION_base(4,9,0)
  fail   = (finalise >>) . failZ
#elif !MIN_VERSION_base(4,13,0)
  fail   = Fail.fail
#endif

#if MIN_VERSION_base(4,9,0)
instance Fail.MonadFail Stream where
  fail   = (finalise >>) . failZ
#endif

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

data State s = State !(ForeignPtr StreamState)
                     !(ForeignPtr Word8)
                     !(ForeignPtr Word8)
      {-# UNPACK #-} !Int
      {-# UNPACK #-} !Int

mkState :: ST s (State s)
mkState = unsafeIOToST $ do
  stream <- mallocForeignPtrBytes (#{const sizeof(z_stream)})
  withForeignPtr stream $ \ptr -> do
    #{poke z_stream, msg}       ptr nullPtr
    #{poke z_stream, zalloc}    ptr nullPtr
    #{poke z_stream, zfree}     ptr nullPtr
    #{poke z_stream, opaque}    ptr nullPtr
    #{poke z_stream, next_in}   ptr nullPtr
    #{poke z_stream, next_out}  ptr nullPtr
    #{poke z_stream, avail_in}  ptr (0 :: CUInt)
    #{poke z_stream, avail_out} ptr (0 :: CUInt)
  return (State stream nullForeignPtr nullForeignPtr 0 0)

runStream :: Stream a -> State s -> ST s (a, State s)
runStream (Z m) (State stream inBuf outBuf outOffset outLength) =
  unsafeIOToST $
    m stream inBuf outBuf outOffset outLength >>=
      \(inBuf', outBuf', outOffset', outLength', a) ->
        return (a, State stream inBuf' outBuf' outOffset' outLength')

-- This is marked as unsafe because runStream uses unsafeIOToST so anything
-- lifted here can end up being unsafePerformIO'd.
unsafeLiftIO :: IO a -> Stream a
unsafeLiftIO m = Z $ \_stream inBuf outBuf outOffset outLength -> do
  a <- m
  return (inBuf, outBuf, outOffset, outLength, a)

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

#ifdef DEBUG
trace :: String -> Stream ()
trace = unsafeLiftIO . hPutStrLn stderr

dump :: Stream ()
dump = do
  inNext  <- getInNext
  inAvail <- getInAvail

  outNext <- getOutNext
  outFree <- getOutFree
  outAvail <- getOutAvail
  outOffset <- getOutOffset

  unsafeLiftIO $ hPutStrLn stderr $
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
#endif


----------------------------
-- zlib wrapper layer
--

data Status =
    Ok
  | StreamEnd
  | Error ErrorCode String

data ErrorCode =
    NeedDict DictionaryHash
  | FileError
  | StreamError
  | DataError
  | MemoryError
  | BufferError -- ^ No progress was possible or there was not enough room in
                --   the output buffer when 'Finish' is used. Note that
                --   'BufferError' is not fatal, and 'inflate' can be called
                --   again with more input and more output space to continue.
  | VersionError
  | Unexpected

toStatus :: CInt -> Stream Status
toStatus errno = case errno of
  (#{const Z_OK})            -> return Ok
  (#{const Z_STREAM_END})    -> return StreamEnd
  (#{const Z_NEED_DICT})     -> do
    adler <- withStreamPtr (#{peek z_stream, adler})
    err (NeedDict (DictHash adler))  "custom dictionary needed"
  (#{const Z_BUF_ERROR})     -> err BufferError  "buffer error"
  (#{const Z_ERRNO})         -> err FileError    "file error"
  (#{const Z_STREAM_ERROR})  -> err StreamError  "stream error"
  (#{const Z_DATA_ERROR})    -> err DataError    "data error"
  (#{const Z_MEM_ERROR})     -> err MemoryError  "insufficient memory"
  (#{const Z_VERSION_ERROR}) -> err VersionError "incompatible zlib version"
  other                      -> return $ Error Unexpected
                                  ("unexpected zlib status: " ++ show other)
 where
   err errCode altMsg = liftM (Error errCode) $ do
    msgPtr <- withStreamPtr (#{peek z_stream, msg})
    if msgPtr /= nullPtr
     then unsafeLiftIO (peekCAString msgPtr)
     else return altMsg

failIfError :: CInt -> Stream ()
failIfError errno = toStatus errno >>= \status -> case status of
  (Error _ msg) -> fail msg
  _             -> return ()


data Flush =
    NoFlush
  | SyncFlush
  | FullFlush
  | Finish
  | Block

fromFlush :: Flush -> CInt
fromFlush NoFlush   = #{const Z_NO_FLUSH}
fromFlush SyncFlush = #{const Z_SYNC_FLUSH}
fromFlush FullFlush = #{const Z_FULL_FLUSH}
fromFlush Finish    = #{const Z_FINISH}
fromFlush Block     = #{const Z_BLOCK}


-- | The format used for compression or decompression. There are three
-- variations.
--
data Format = GZip | Zlib | Raw | GZipOrZlib
  deriving (Eq, Ord, Enum, Bounded, Show
              , Generic
           )

-- | The gzip format uses a header with a checksum and some optional meta-data
-- about the compressed file. It is intended primarily for compressing
-- individual files but is also sometimes used for network protocols such as
-- HTTP. The format is described in detail in RFC #1952
-- <http://www.ietf.org/rfc/rfc1952.txt>
--
gzipFormat :: Format
gzipFormat = GZip

-- | The zlib format uses a minimal header with a checksum but no other
-- meta-data. It is especially designed for use in network protocols. The
-- format is described in detail in RFC #1950
-- <http://www.ietf.org/rfc/rfc1950.txt>
--
zlibFormat :: Format
zlibFormat = Zlib

-- | The \'raw\' format is just the compressed data stream without any
-- additional header, meta-data or data-integrity checksum. The format is
-- described in detail in RFC #1951 <http://www.ietf.org/rfc/rfc1951.txt>
--
rawFormat :: Format
rawFormat = Raw

-- | This is not a format as such. It enabled zlib or gzip decoding with
-- automatic header detection. This only makes sense for decompression.
--
gzipOrZlibFormat :: Format
gzipOrZlibFormat = GZipOrZlib

formatSupportsDictionary :: Format -> Bool
formatSupportsDictionary Zlib = True
formatSupportsDictionary Raw  = True
formatSupportsDictionary _    = False

-- | The compression method
--
data Method = Deflated
  deriving (Eq, Ord, Enum, Bounded, Show
              , Generic
           )

-- | The only method supported in this version of zlib.
-- Indeed it is likely to be the only method that ever will be supported.
--
deflateMethod :: Method
deflateMethod = Deflated

fromMethod :: Method -> CInt
fromMethod Deflated = #{const Z_DEFLATED}


-- | The compression level parameter controls the amount of compression. This
-- is a trade-off between the amount of compression and the time required to do
-- the compression.
--
newtype CompressionLevel = CompressionLevel Int
  deriving
  ( Eq
  , Ord -- ^ @since 0.7.0.0
  , Show
  , Generic
  )

-- | The default t'CompressionLevel'.
defaultCompression :: CompressionLevel
defaultCompression = CompressionLevel 6

-- Ideally we should use #{const Z_DEFAULT_COMPRESSION} = -1, whose meaning
-- depends on zlib version and, strictly speaking, is not guaranteed to be 6.
-- It would however interact badly with Eq / Ord instances.

-- | No compression, just a block copy.
noCompression :: CompressionLevel
noCompression = CompressionLevel #{const Z_NO_COMPRESSION}

-- | The fastest compression method (less compression).
bestSpeed :: CompressionLevel
bestSpeed = CompressionLevel #{const Z_BEST_SPEED}

-- | The slowest compression method (best compression).
bestCompression :: CompressionLevel
bestCompression = CompressionLevel #{const Z_BEST_COMPRESSION}

-- | A specific compression level in the range @0..9@.
-- Throws an error for arguments outside of this range.
--
-- * 0 stands for 'noCompression',
-- * 1 stands for 'bestSpeed',
-- * 6 stands for 'defaultCompression',
-- * 9 stands for 'bestCompression'.
--
compressionLevel :: Int -> CompressionLevel
compressionLevel n
  | n >= 0 && n <= 9 = CompressionLevel n
  | otherwise         = error "CompressionLevel must be in the range 0..9"

fromCompressionLevel :: CompressionLevel -> CInt
fromCompressionLevel (CompressionLevel n)
           | n >= 0 && n <= 9 = int2cint n
           | otherwise        = error "CompressLevel must be in the range 0..9"


-- | This specifies the size of the compression window. Larger values of this
-- parameter result in better compression at the expense of higher memory
-- usage.
--
-- The compression window size is the value of the the window bits raised to
-- the power 2. The window bits must be in the range @9..15@ which corresponds
-- to compression window sizes of 512b to 32Kb. The default is 15 which is also
-- the maximum size.
--
-- The total amount of memory used depends on the window bits and the
-- t'MemoryLevel'. See the t'MemoryLevel' for the details.
--
newtype WindowBits = WindowBits Int
  deriving
  ( Eq
  , Ord
  , Show
  , Generic
  )

-- zlib manual (https://www.zlib.net/manual.html#Advanced) says that WindowBits
-- could be in the range 8..15, but for some reason we require 9..15.
-- Could it be that older versions of zlib had a tighter limit?..

-- | The default t'WindowBits'. Equivalent to @'windowBits' 15@.
-- which is also the maximum size.
--
defaultWindowBits :: WindowBits
defaultWindowBits = WindowBits 15

-- | A specific compression window size, specified in bits in the range @9..15@.
-- Throws an error for arguments outside of this range.
--
windowBits :: Int -> WindowBits
windowBits n
  | n >= 9 && n <= 15 = WindowBits n
  | otherwise         = error "WindowBits must be in the range 9..15"

fromWindowBits :: Format -> WindowBits -> CInt
fromWindowBits format bits = (formatModifier format) (checkWindowBits bits)
  where checkWindowBits (WindowBits n)
          | n >= 9 && n <= 15 = int2cint n
          | otherwise         = error "WindowBits must be in the range 9..15"
        formatModifier Zlib       = id
        formatModifier GZip       = (+16)
        formatModifier GZipOrZlib = (+32)
        formatModifier Raw        = negate


-- | The t'MemoryLevel' parameter specifies how much memory should be allocated
-- for the internal compression state. It is a trade-off between memory usage,
-- compression ratio and compression speed. Using more memory allows faster
-- compression and a better compression ratio.
--
-- The total amount of memory used for compression depends on the t'WindowBits'
-- and the t'MemoryLevel'. For decompression it depends only on the
-- t'WindowBits'. The totals are given by the functions:
--
-- > compressTotal windowBits memLevel = 4 * 2^windowBits + 512 * 2^memLevel
-- > decompressTotal windowBits = 2^windowBits
--
-- For example, for compression with the default @windowBits = 15@ and
-- @memLevel = 8@ uses @256Kb@. So for example a network server with 100
-- concurrent compressed streams would use @25Mb@. The memory per stream can be
-- halved (at the cost of somewhat degraded and slower compression) by
-- reducing the @windowBits@ and @memLevel@ by one.
--
-- Decompression takes less memory, the default @windowBits = 15@ corresponds
-- to just @32Kb@.
--
newtype MemoryLevel = MemoryLevel Int
  deriving
  ( Eq
  , Ord -- ^ @since 0.7.0.0
  , Show
  , Generic
  )

-- | The default t'MemoryLevel'. Equivalent to @'memoryLevel' 8@.
--
defaultMemoryLevel :: MemoryLevel
defaultMemoryLevel = MemoryLevel 8

-- | Use minimum memory. This is slow and reduces the compression ratio.
-- Equivalent to @'memoryLevel' 1@.
--
minMemoryLevel :: MemoryLevel
minMemoryLevel = MemoryLevel 1

-- | Use maximum memory for optimal compression speed.
-- Equivalent to @'memoryLevel' 9@.
--
maxMemoryLevel :: MemoryLevel
maxMemoryLevel = MemoryLevel 9

-- | A specific memory level in the range @1..9@.
-- Throws an error for arguments outside of this range.
--
memoryLevel :: Int -> MemoryLevel
memoryLevel n
  | n >= 1 && n <= 9 = MemoryLevel n
  | otherwise        = error "MemoryLevel must be in the range 1..9"

fromMemoryLevel :: MemoryLevel -> CInt
fromMemoryLevel (MemoryLevel n)
         | n >= 1 && n <= 9 = int2cint n
         | otherwise        = error "MemoryLevel must be in the range 1..9"


-- | The strategy parameter is used to tune the compression algorithm.
--
-- The strategy parameter only affects the compression ratio but not the
-- correctness of the compressed output even if it is not set appropriately.
--
data CompressionStrategy =
    DefaultStrategy
  | Filtered
  | HuffmanOnly
  | RLE
  -- ^ @since 0.7.0.0
  | Fixed
  -- ^ @since 0.7.0.0
  deriving (Eq, Ord, Enum, Bounded, Show
              , Generic
           )

-- | Use this default compression strategy for normal data.
--
defaultStrategy :: CompressionStrategy
defaultStrategy = DefaultStrategy

-- | Use the filtered compression strategy for data produced by a filter (or
-- predictor). Filtered data consists mostly of small values with a somewhat
-- random distribution. In this case, the compression algorithm is tuned to
-- compress them better. The effect of this strategy is to force more Huffman
-- coding and less string matching; it is somewhat intermediate between
-- 'defaultStrategy' and 'huffmanOnlyStrategy'.
--
filteredStrategy :: CompressionStrategy
filteredStrategy = Filtered

-- | Use the Huffman-only compression strategy to force Huffman encoding only
-- (no string match).
--
huffmanOnlyStrategy :: CompressionStrategy
huffmanOnlyStrategy = HuffmanOnly

-- | Use 'rleStrategy' to limit match distances to one (run-length
-- encoding). 'rleStrategy' is designed to be almost as fast as
-- 'huffmanOnlyStrategy', but give better compression for PNG
-- image data.
--
-- @since 0.7.0.0
rleStrategy :: CompressionStrategy
rleStrategy = RLE

-- | 'fixedStrategy' prevents the use of dynamic Huffman codes,
-- allowing for a simpler decoder for special applications.
--
-- @since 0.7.0.0
fixedStrategy :: CompressionStrategy
fixedStrategy = Fixed

fromCompressionStrategy :: CompressionStrategy -> CInt
fromCompressionStrategy DefaultStrategy = #{const Z_DEFAULT_STRATEGY}
fromCompressionStrategy Filtered        = #{const Z_FILTERED}
fromCompressionStrategy HuffmanOnly     = #{const Z_HUFFMAN_ONLY}
fromCompressionStrategy RLE             = #{const Z_RLE}
fromCompressionStrategy Fixed           = #{const Z_FIXED}

withStreamPtr :: (Ptr StreamState -> IO a) -> Stream a
withStreamPtr f = do
  stream <- getStreamState
  unsafeLiftIO (withForeignPtr stream f)

withStreamState :: (StreamState -> IO a) -> Stream a
withStreamState f = do
  stream <- getStreamState
  unsafeLiftIO (withForeignPtr stream (f . StreamState))

setInAvail :: CUInt -> Stream ()
setInAvail val = withStreamPtr $ \ptr ->
  #{poke z_stream, avail_in} ptr val

getInAvail :: Stream Int
getInAvail = liftM cuint2int $
  withStreamPtr (#{peek z_stream, avail_in})

setInNext :: Ptr Word8 -> Stream ()
setInNext val = withStreamPtr (\ptr -> #{poke z_stream, next_in} ptr val)

getInNext :: Stream (Ptr Word8)
getInNext = withStreamPtr (#{peek z_stream, next_in})

setOutFree :: CUInt -> Stream ()
setOutFree val = withStreamPtr $ \ptr ->
  #{poke z_stream, avail_out} ptr val

getOutFree :: Stream Int
getOutFree = liftM cuint2int $
  withStreamPtr (#{peek z_stream, avail_out})

setOutNext  :: Ptr Word8 -> Stream ()
setOutNext val = withStreamPtr (\ptr -> #{poke z_stream, next_out} ptr val)

#ifdef DEBUG
getOutNext :: Stream (Ptr Word8)
getOutNext = withStreamPtr (#{peek z_stream, next_out})
#endif

inflateInit :: Format -> WindowBits -> Stream ()
inflateInit format bits = do
  checkFormatSupported format
  err <- withStreamState $ \zstream ->
    c_inflateInit2 zstream (fromWindowBits format bits)
  failIfError err
  getStreamState >>= unsafeLiftIO . addForeignPtrFinalizer c_inflateEnd

deflateInit :: Format
            -> CompressionLevel
            -> Method
            -> WindowBits
            -> MemoryLevel
            -> CompressionStrategy
            -> Stream ()
deflateInit format compLevel method bits memLevel strategy = do
  checkFormatSupported format
  err <- withStreamState $ \zstream ->
    c_deflateInit2 zstream
                  (fromCompressionLevel compLevel)
                  (fromMethod method)
                  (fromWindowBits format bits)
                  (fromMemoryLevel memLevel)
                  (fromCompressionStrategy strategy)
  failIfError err
  getStreamState >>= unsafeLiftIO . addForeignPtrFinalizer c_deflateEnd

inflate_ :: Flush -> Stream Status
inflate_ flush = do
  err <- withStreamState $ \zstream ->
    c_inflate zstream (fromFlush flush)
  toStatus err

deflate_ :: Flush -> Stream Status
deflate_ flush = do
  err <- withStreamState $ \zstream ->
    c_deflate zstream (fromFlush flush)
  toStatus err

-- | This never needs to be used as the stream's resources will be released
-- automatically when no longer needed, however this can be used to release
-- them early. Only use this when you can guarantee that the stream will no
-- longer be needed, for example if an error occurs or if the stream ends.
--
finalise :: Stream ()
--TODO: finalizeForeignPtr is ghc-only
finalise = getStreamState >>= unsafeLiftIO . finalizeForeignPtr

checkFormatSupported :: Format -> Stream ()
checkFormatSupported format = do
  version <- unsafeLiftIO (coerce peekCAString =<< c_zlibVersion)
  case version of
    ('1':'.':'1':'.':_)
       | format == GZip
      || format == GZipOrZlib
      -> fail $ "version 1.1.x of the zlib C library does not support the"
             ++ " 'gzip' format via the in-memory api, only the 'raw' and "
             ++ " 'zlib' formats."
    _ -> return ()

-- | This one should not fail on 64-bit arch.
cuint2int :: CUInt -> Int
cuint2int n = fromMaybe (error $ "cuint2int: cannot cast " ++ show n) $ toIntegralSized n

-- | This one could and will fail if chunks of ByteString are longer than 4G.
int2cuint :: Int -> CUInt
int2cuint n = fromMaybe (error $ "int2cuint: cannot cast " ++ show n) $ toIntegralSized n

-- | This one could fail in theory, but is used only on arguments 0..9 or 0..15.
int2cint :: Int -> CInt
int2cint n = fromMaybe (error $ "int2cint: cannot cast " ++ show n) $ toIntegralSized n

----------------------
-- The foreign imports

newtype StreamState = StreamState (Ptr StreamState)

##ifdef NON_BLOCKING_FFI
##define SAFTY safe
##else
##define SAFTY unsafe
##endif

foreign import capi unsafe "zlib.h inflateInit2"
  c_inflateInit2 :: StreamState -> CInt -> IO CInt
 
foreign import capi unsafe "zlib.h deflateInit2"
  c_deflateInit2 :: StreamState
                 -> CInt -> CInt -> CInt -> CInt -> CInt -> IO CInt

foreign import capi SAFTY "zlib.h inflate"
  c_inflate :: StreamState -> CInt -> IO CInt

foreign import capi unsafe "hs-zlib.h &_hs_zlib_inflateEnd"
  c_inflateEnd :: FinalizerPtr StreamState

foreign import capi unsafe "zlib.h inflateReset"
  c_inflateReset :: StreamState -> IO CInt

foreign import capi unsafe "zlib.h deflateSetDictionary"
  c_deflateSetDictionary :: StreamState
                         -> Ptr CUChar
                         -> CUInt
                         -> IO CInt

foreign import capi unsafe "zlib.h inflateSetDictionary"
  c_inflateSetDictionary :: StreamState
                         -> Ptr CUChar
                         -> CUInt
                         -> IO CInt

foreign import capi SAFTY "zlib.h deflate"
  c_deflate :: StreamState -> CInt -> IO CInt

foreign import capi unsafe "hs-zlib.h &_hs_zlib_deflateEnd"
  c_deflateEnd :: FinalizerPtr StreamState

#if MIN_VERSION_base(4,18,0)
foreign import capi unsafe "zlib.h zlibVersion"
  c_zlibVersion :: IO (ConstPtr CChar)
#else
foreign import ccall unsafe "zlib.h zlibVersion"
  c_zlibVersion :: IO (Ptr CChar)
#endif

foreign import capi unsafe "zlib.h adler32"
  c_adler32 :: CULong
            -> Ptr CUChar
            -> CUInt
            -> IO CULong
