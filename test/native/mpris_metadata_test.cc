#include <os_media_controls/os_media_controls_plugin.h>

#include <glib/gstdio.h>

namespace os_media_controls {

void TestMprisMetadataReplacement() {
  OsMediaControlsPluginImpl plugin(nullptr, nullptr);
  g_assert_true(plugin.mpris_initialized_);
  auto read_metadata = [&]() {
    return g_variant_ref_sink(OsMediaControlsPluginImpl::HandleGetProperty(
        nullptr, nullptr, nullptr, "org.mpris.MediaPlayer2.Player", "Metadata", nullptr, &plugin));
  };
  constexpr uint8_t cover[] = {1, 2, 3};
  g_autoptr(FlValue) first = fl_value_new_map();
  fl_value_set_string_take(first, "title", fl_value_new_string("Song"));
  fl_value_set_string_take(first, "artist", fl_value_new_string("Singer"));
  fl_value_set_string_take(first, "album", fl_value_new_string("Album"));
  fl_value_set_string_take(first, "albumArtist", fl_value_new_string("Ensemble"));
  fl_value_set_string_take(first, "duration", fl_value_new_float(185));
  fl_value_set_string_take(first, "artwork", fl_value_new_uint8_list(cover, sizeof(cover)));
  plugin.SetMetadata(first);

  g_autoptr(GVariant) tagged = read_metadata();
  const gchar* uri = nullptr;
  gint64 length = 0;
  g_assert_true(g_variant_lookup(tagged, "mpris:length", "x", &length));
  g_assert_cmpint(length, ==, 185000000);
  g_assert_true(g_variant_lookup(tagged, "mpris:artUrl", "&s", &uri));
  g_autofree gchar* old_cover = g_filename_from_uri(uri, nullptr, nullptr);
  g_assert_true(g_file_test(old_cover, G_FILE_TEST_EXISTS));

  g_autoptr(FlValue) next = fl_value_new_map();
  fl_value_set_string_take(next, "title", fl_value_new_string("Broadcast"));
  plugin.SetMetadata(next);
  g_autoptr(GVariant) bare = read_metadata();
  const gchar* title = nullptr;
  g_assert_true(g_variant_lookup(bare, "xesam:title", "&s", &title));
  g_assert_cmpstr(title, ==, "Broadcast");
  for (const char* field : {"xesam:artist", "xesam:album", "xesam:albumArtist", "mpris:length", "mpris:artUrl"}) {
    g_assert_null(g_variant_lookup_value(bare, field, nullptr));
  }
  g_assert_false(g_file_test(old_cover, G_FILE_TEST_EXISTS));

  // Dart sends the same item's complete fields again when its image arrives.
  fl_value_set_string_take(next, "artwork", fl_value_new_uint8_list(cover, sizeof(cover)));
  plugin.SetMetadata(next);
  g_autoptr(GVariant) enriched = read_metadata();
  g_assert_true(g_variant_lookup(enriched, "xesam:title", "&s", &title));
  g_assert_cmpstr(title, ==, "Broadcast");
  g_assert_true(g_variant_lookup(enriched, "mpris:artUrl", "&s", &uri));
  g_assert_null(g_variant_lookup_value(enriched, "xesam:artist", nullptr));
}

}  // namespace os_media_controls

int main() {
  g_autofree gchar* runtime = g_dir_make_tmp("pleazyng-mpris-test-XXXXXX", nullptr);
  g_assert_nonnull(runtime);
  g_setenv("XDG_RUNTIME_DIR", runtime, true);
  os_media_controls::TestMprisMetadataReplacement();
  g_assert_cmpint(g_rmdir(runtime), ==, 0);
}
