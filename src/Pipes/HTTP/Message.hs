{-# LANGUAGE RankNTypes #-}

module Pipes.HTTP.Message
 ( parseResponses
 ) where

import           Control.Applicative
import           Control.Monad.Trans.Free      (FreeT(..), FreeF(..))
import           Data.ByteString               (ByteString)
import qualified Data.ByteString.Char8         as B8
import           Data.Word                     (Word)
import qualified Network.HTTP.Types            as H
import           Pipes
import qualified Pipes.Attoparsec              as Pa
import qualified Pipes.ByteString              as Pb
import           Pipes.HTTP.Message.Attoparsec (pResponseLine, pHeaders)
import           Pipes.HTTP.Message.Types      (Response(..), ResponseLine)
import qualified Pipes.Parse                   as Pp

--------------------------------------------------------------------------------

data BadHttpMessage
  = BadLeadingLine
  | BadHeaders
  | BadBodyShape
  deriving (Eq, Read, Show)

data BodyShape
  = Single Word
  -- | Chunked ... something ...
  deriving (Eq, Read, Show)

--------------------------------------------------------------------------------

parseResponses
 :: Monad m
 => Producer ByteString m r
 -> FreeT (Response m) m (Either BadHttpMessage (), Producer ByteString m r)
parseResponses p0 = FreeT $ do
    (er1, p1) <- Pp.runStateT pResponseLead p0
    return $ case er1 of
      Left  e1           -> Pure (Left e1, p1)
      Right (line, hdrs) -> case bodyShape hdrs of
        Nothing -> Pure (Left BadBodyShape, p1)
        Just s  -> Free (Response line hdrs $ parseResponses <$> splitBody s p1)


-- | Determine the shape of an HTTP message body based on the header values
--
-- This implementation only understands the "Content-Length" header.
bodyShape :: [H.Header] -> Maybe BodyShape
bodyShape headers =
    Single . read . B8.unpack <$> lookup H.hContentLength headers


-- | Forwards downstream a single `BodyShape` from the given `Producer`,
-- returning any leftovers.
splitBody
  :: Monad m
  => BodyShape
  -> Producer  ByteString m r
  -> Producer' ByteString m (Producer ByteString m r)
splitBody shape p = case shape of
    Single len -> Pb.splitAt len p

--------------------------------------------------------------------------------

pResponseLead
  :: Monad m
  => Pp.StateT (Producer ByteString m r) m
               (Either BadHttpMessage (ResponseLine, [H.Header]))
pResponseLead = do
    er1 <- Pa.parse pResponseLine
    case er1 of
      Left  _          -> return $ Left BadLeadingLine
      Right (_,r1)     -> do
        er2 <- Pa.parse pHeaders
        case er2 of
          Left  _      -> return $ Left BadHeaders
          Right (_,r2) -> return $ Right (r1, r2)
