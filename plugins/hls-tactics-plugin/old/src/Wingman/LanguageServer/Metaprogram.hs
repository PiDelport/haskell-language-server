{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings     #-}

{-# LANGUAGE NoMonoLocalBinds  #-}
{-# LANGUAGE RankNTypes #-}

module Wingman.LanguageServer.Metaprogram
  ( hoverProvider
  ) where

import           Control.Applicative (empty)
import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Trans.Maybe
import           Data.List (find)
import           Data.Maybe
import qualified Data.Text as T
import           Development.IDE (positionToRealSrcLoc, realSrcSpanToRange)
import           Development.IDE.Core.Shake (IdeState (..))
import           Development.IDE.Core.UseStale
import           Development.IDE.GHC.Compat hiding (empty)
import           Ide.Types
import           Language.LSP.Protocol.Types
import           Language.LSP.Protocol.Message
import           Prelude hiding (span)
import           Wingman.LanguageServer
import           Wingman.Metaprogramming.Parser (attempt_it)
import           Wingman.Types


------------------------------------------------------------------------------
-- | Provide the "empty case completion" code lens
hoverProvider :: PluginMethodHandler IdeState Method_TextDocumentHover
hoverProvider state plId (HoverParams (TextDocumentIdentifier uri) (unsafeMkCurrent -> pos) _)
  | Just nfp <- uriToNormalizedFilePath $ toNormalizedUri uri = do
      let loc = fmap (realSrcLocSpan . positionToRealSrcLoc nfp) pos
          stale = unsafeRunStaleIdeFast "hoverProvider" state nfp

      cfg <- liftIO $ runIde "plugin" "config" state (getTacticConfigAction plId)
      (fmap . fmap) maybeToNull <$> liftIO $ fromMaybeT (Right Nothing) $ do
        holes <- stale GetMetaprograms

        fmap (Right . Just) $
          case find (flip containsSpan (unTrack loc) . unTrack . fst) holes of
            Just (trss, program) -> do
              let tr_range = fmap realSrcSpanToRange trss
                  rsl = realSrcSpanStart $ unTrack trss
              HoleJudgment{hj_jdg=jdg, hj_ctx=ctx} <- judgementForHole state nfp tr_range cfg
              z <- liftIO $ attempt_it rsl ctx jdg $ T.unpack program
              pure $ Hover
                { _contents = InL
                            $ MarkupContent MarkupKind_Markdown
                            $ either T.pack T.pack z
                , _range = Just $ unTrack tr_range
                }
            Nothing -> empty
hoverProvider _ _ _ = pure $ Right $ InR Null

fromMaybeT :: Functor m => a -> MaybeT m a -> m a
fromMaybeT def = fmap (fromMaybe def) . runMaybeT
