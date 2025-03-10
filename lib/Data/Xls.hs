-- |
-- Module      : Data.Xls
-- Copyright   : (c) 2016 Harendra Kumar
--
-- License     : BSD-style
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
-- Parse Microsoft excel spreadsheet xls file (format BIFF/Excel 97-2004).
--
{-# OPTIONS_GHC -pgmP cpp #-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE RankNTypes #-}
#if __GLASGOW_HASKELL__ < 7100
{-# LANGUAGE DeriveDataTypeable #-}
#endif

module Data.Xls
    ( decodeXlsIO
    , decodeXls
    , XlsException(..)
    )
where

import           Control.Exception (Exception, throwIO, bracket)
import           Control.Monad.IO.Class
import           Control.Monad (when, void)
import           Control.Monad.Trans.Resource
import           Data.Conduit hiding (Conduit, Sink, Source)
import           Data.Data
import           Data.Int
import           Data.Maybe (catMaybes, fromJust, isJust, fromMaybe)
import           Foreign.C
import           Foreign.Ptr
import           Text.Printf

#define CCALL(name,signature) \
foreign import ccall unsafe #name \
    c_##name :: signature

-- Workbook accessor functions
data XLSWorkbookStruct
type XLSWorkbook = Ptr XLSWorkbookStruct

CCALL(xls_open,          CString -> CString -> IO XLSWorkbook)
CCALL(xls_wb_sheetcount, XLSWorkbook -> IO CInt -- Int32)
CCALL(xls_close_WB,      XLSWorkbook -> IO ())

-- Worksheet accessor functions
data XLSWorksheetStruct
type XLSWorksheet = Ptr XLSWorksheetStruct

CCALL(xls_getWorkSheet, XLSWorkbook -> CInt -> IO XLSWorksheet)

CCALL(xls_parseWorkSheet, XLSWorksheet -> IO ())
CCALL(xls_ws_rowcount,    XLSWorksheet -> IO Int16 -- Int16)
CCALL(xls_ws_colcount,    XLSWorksheet -> IO Int16 -- Int16)
CCALL(xls_close_WS,       XLSWorksheet -> IO ())

-- Cell accessor functions
data XLSCellStruct
type XLSCell = Ptr XLSCellStruct

CCALL(xls_cell, XLSWorksheet -> Int16 -> Int16 -> IO XLSCell)

CCALL(xls_cell_type,            XLSCell -> IO Int16 -- Int16)
CCALL(xls_cell_strval,          XLSCell -> IO CString)
CCALL(xls_cell_formulatype,     XLSCell -> IO Int32 -- Int32)
CCALL(xls_cell_numval,          XLSCell -> IO CDouble)
-- CCALL(xls_cell_colspan,         XLSCell -> IO Int16 -- Int16)
-- CCALL(xls_cell_rowspan,         XLSCell -> IO Int16 -- Int16)
CCALL(xls_cell_hidden,          XLSCell -> IO Int8 -- Int8)

data XlsException =
      XlsFileNotFound String
    | XlsParseError String
    deriving (Show, Typeable)

instance Exception XlsException

-- | Parse a Microsoft excel xls workbook file into a Conduit yielding
-- rows in a worksheet. Each row represented by a list of Strings, each String
-- representing an individual cell.
--
-- Important Note: This API concatenates rows from all worksheets into a single
-- stream. Please use the non-streaming 'decodeXlsIO' API to get individual
-- worksheets.
--
-- Throws 'XlsException'
--
decodeXls :: MonadResource m => FilePath -> ConduitM i [String] m ()
decodeXls file =
    bracketP alloc cleanup decodeWorkSheets
    where
        alloc = do
            file' <- newCString file
            pWB <- newCString "UTF-8" >>= c_xls_open file'
            if pWB == nullPtr then
                throwIO $ XlsFileNotFound
                        $ "XLS file " ++ file ++ " not found."
            else
                return pWB

        cleanup = c_xls_close_WB

        decodeWorkSheets pWB = do
            count <- liftIO $ c_xls_wb_sheetcount pWB
            mapM_ (decodeOneWorkSheet file pWB) [0 .. count - 1]


-- | Parse a Microsoft excel xls workbook file into a list of worksheets, each
-- worksheet consists of a list of rows and each row consists of a list of
-- cells.  Cells are plain 'String'.
--
-- Throws 'XlsException'
--
decodeXlsIO
    :: FilePath
    -> IO [[[String]]]
decodeXlsIO file = do
    file' <- newCString file
    pWB <- newCString "UTF-8" >>= c_xls_open file'
    when (pWB == nullPtr) $
        throwIO $ XlsFileNotFound
                $ "XLS file " ++ file ++ " not found."
    count <- liftIO $ c_xls_wb_sheetcount pWB
    results <- mapM (decodeOneWorkSheetIO file pWB) [0 .. count - 1]
    void $ c_xls_close_WB pWB
    return results

decodeOneWorkSheet
    :: MonadResource m
    => FilePath -> XLSWorkbook -> CInt -> ConduitM i [String] m ()
decodeOneWorkSheet file pWB index =
    bracketP alloc cleanup decodeWS
    where
        alloc = do
            pWS <- c_xls_getWorkSheet pWB index
            if pWS == nullPtr then
                throwIO $ XlsParseError
                        $ "XLS file " ++ file ++ " could not be parsed."
            else do
              c_xls_parseWorkSheet pWS
              return pWS

        cleanup = c_xls_close_WS

        decodeWS = decodeRows

decodeOneWorkSheetIO
    :: FilePath
    -> XLSWorkbook
    -> CInt
    -> IO [[String]]
decodeOneWorkSheetIO file pWB index =
    bracket alloc cleanup decodeRowsIO
    where
        alloc = do
            pWS <- c_xls_getWorkSheet pWB index
            if pWS == nullPtr then
                throwIO $ XlsParseError
                        $ "XLS file "
                        ++ file
                        ++ " could not be parsed."
            else do
              c_xls_parseWorkSheet pWS
              return pWS
        cleanup = c_xls_close_WS

decodeRows :: MonadResource m => XLSWorksheet -> ConduitM i [String] m ()
decodeRows pWS = do
    rows <- liftIO $ c_xls_ws_rowcount pWS
    cols <- liftIO $ c_xls_ws_colcount pWS
    mapM_ (decodeOneRow pWS cols) [r | r <- [0 .. rows - 1]]

decodeRowsIO
    :: XLSWorksheet
    -> IO [[String]]
decodeRowsIO pWS = do
    rows <- c_xls_ws_rowcount pWS
    cols <- c_xls_ws_colcount pWS
    mapM (decodeOneRowIO pWS cols) [r | r <- [0 .. rows - 1]]

decodeOneRow
    :: MonadResource m
    => XLSWorksheet -> Int16 -> Int16 -> ConduitM i [String] m ()
decodeOneRow pWS cols rowindex =
    mapM (liftIO . (c_xls_cell pWS rowindex)) [0 .. cols - 1]
        >>= mapM (liftIO . decodeOneCell)
        >>= yield . catMaybes

decodeOneRowIO
    :: XLSWorksheet
    -> Int16
    -> Int16
    -> IO [String]
decodeOneRowIO pWS cols rowindex =
    mapM (c_xls_cell pWS rowindex) [0 .. cols - 1]
        >>= mapM decodeOneCell
        >>= pure . (map $ fromMaybe "")

data CellType = Numerical | Formula | Str | Other

decodeOneCell :: XLSCell -> IO (Maybe String)
decodeOneCell cellPtr = do
    nil <- isNullCell cellPtr
    if nil then
        return Nothing
    else cellValue cellPtr >>= return . Just

    where
        isNullCell ptr =
            if ptr == nullPtr then
                return True
            else do
                hidden <- c_xls_cell_hidden ptr
                if hidden /= 0 then
                    return True
                else
                    return False

        cellValue ptr = do
            typ     <- c_xls_cell_type ptr
            numval  <- c_xls_cell_numval ptr
            ftype   <- c_xls_cell_formulatype ptr
            --rowspan <- c_xls_cell_rowspan ptr
            --colspan <- c_xls_cell_colspan ptr
            pStr    <- c_xls_cell_strval ptr
            strval  <-
                if pStr /= nullPtr then
                    peekCString pStr >>= return . Just
                else
                    return Nothing

            return $ case cellType typ ftype strval of
                Numerical   -> outputNum numval
                Formula     -> decodeFormula strval numval
                Str         -> fromJust strval
                Other       -> "" -- we don't decode anything else

        decodeFormula str numval =
            case str of
                Just "bool"  -> outputBool numval
                Just "error" -> "*error*"
                Just x       -> x
                Nothing      -> "" -- is it possible?

        outputNum  d = printf "%.15g" (uncurry encodeFloat (decodeFloat d)
                                       :: Double)
        outputBool d = if d == 0 then "false" else "true"

        cellType t ftype strval =
            if t == 0x27e || t == 0x0BD || t == 0x203 then
                Numerical
            else if t == 0x06 then
                if ftype == 0 then
                    Numerical
                else
                    Formula
            else if isJust strval then
                Str
            else
                Other
