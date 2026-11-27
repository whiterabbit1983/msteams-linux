use glib::prelude::ObjectExt;
use webkit2gtk::Settings;

/// WebKitGTK 2.48 can crash inside Skia when presenting a captured 2D canvas
/// on Mesa software rendering. Do not turn off compositing or video decoding.
pub fn configure(settings: &Settings) {
    let software = match std::env::var("MSTEAMS_SOFTWARE_CANVAS").as_deref() {
        Ok("1") => true,
        Ok("0") => false,
        _ => !std::fs::read_dir("/dev/dri")
            .into_iter()
            .flatten()
            .flatten()
            .any(|entry| entry.file_name().to_string_lossy().starts_with("renderD")),
    };
    let property = "enable-2d-canvas-acceleration";
    if software && settings.find_property(property).is_some() {
        settings.set_property(property, false);
    }
}
