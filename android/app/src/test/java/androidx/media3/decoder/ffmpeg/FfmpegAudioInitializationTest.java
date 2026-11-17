package androidx.media3.decoder.ffmpeg;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;

import androidx.media3.common.MimeTypes;
import java.util.Arrays;
import java.util.Collections;
import org.junit.Test;

public class FfmpegAudioInitializationTest {
  @Test
  public void matchesMpegLayersAndDtsExpressToTheirDecoders() {
    assertEquals("mp1", FfmpegLibrary.getCodecName(MimeTypes.AUDIO_MPEG_L1));
    assertEquals("mp2", FfmpegLibrary.getCodecName(MimeTypes.AUDIO_MPEG_L2));
    assertEquals("mp3", FfmpegLibrary.getCodecName(MimeTypes.AUDIO_MPEG));
    assertEquals("dca", FfmpegLibrary.getCodecName(MimeTypes.AUDIO_DTS_EXPRESS));
  }

  @Test
  public void handlesAbsentHeadersByCodec() throws Exception {
    assertNull(FfmpegAudioDecoder.getExtraData(MimeTypes.AUDIO_AAC, Collections.emptyList()));
    assertNull(FfmpegAudioDecoder.getExtraData(MimeTypes.AUDIO_OPUS, Collections.emptyList()));
    assertThrows(FfmpegDecoderException.class,
        () -> FfmpegAudioDecoder.getExtraData(MimeTypes.AUDIO_ALAC, Collections.emptyList()));
    assertThrows(FfmpegDecoderException.class,
        () -> FfmpegAudioDecoder.getExtraData(MimeTypes.AUDIO_VORBIS, Collections.singletonList(new byte[30])));
  }

  @Test
  public void retainsVorbisSetupLargerThan65535Bytes() throws Exception {
    byte[] identification = new byte[30];
    byte[] setup = new byte[70000];
    Arrays.fill(setup, (byte) 5);
    byte[] actual = FfmpegAudioDecoder.getExtraData(MimeTypes.AUDIO_VORBIS, Arrays.asList(identification, setup));
    assertEquals(2, actual[0]);
    assertEquals(30, actual[1]);
    assertEquals(0, actual[2]);
    assertArrayEquals(identification, Arrays.copyOfRange(actual, 3, 33));
    assertArrayEquals(setup, Arrays.copyOfRange(actual, 33, actual.length));
  }
}
