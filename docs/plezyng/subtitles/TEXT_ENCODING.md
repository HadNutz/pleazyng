# Subtitle text encoding preview

The subtitle sync and repair picker opens a cue preview before accepting a text
subtitle. It defaults to strict UTF-8 or BOM-marked UTF-16. When a file uses a
legacy code page or BOM-less UTF-16, choose its encoding explicitly and review
the rendered cues before continuing. The app does not infer legacy encodings;
some byte sequences are valid under several encodings and produce different
text.

The selector includes Windows-1250–1258, ISO-8859-1/2/5/6/7/8/9/15, KOI8-R/U,
DOS-437/850/866, CP932/Shift-JIS, GBK, GB18030, Big5, CP949/UHC, and BOM-less
UTF-16LE/BE. BOM-marked files must use the Unicode option. Undefined, truncated,
or malformed sequences and binary control characters are rejected rather than
replaced. Review at least one displayed cue before selecting **Use this
preview**.

The preview reads the selected file bytes and derives cue text in memory. It
does not rewrite, normalize, or replace the source file. Generated subtitle
revisions remain separate outputs. The legacy mapping tables are generated
from CPython 3.12.14 standard-library codecs by
[`tools/generate_subtitle_codecs.py`](../../../tools/generate_subtitle_codecs.py).
