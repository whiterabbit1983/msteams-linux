//! Launch host desktop applications without the AppImage's GTK/loader paths.
use std::{
    collections::HashMap,
    ffi::OsString,
    path::Path,
    process::{Command, Stdio},
    sync::atomic::{AtomicUsize, Ordering},
};

type Environment = HashMap<OsString, OsString>;
static ACTIVE_LAUNCHERS: AtomicUsize = AtomicUsize::new(0);

struct LaunchPermit;

impl LaunchPermit {
    fn acquire() -> Result<Self, String> {
        let mut active = ACTIVE_LAUNCHERS.load(Ordering::Relaxed);
        loop {
            if active >= 4 {
                return Err("Too many browser launchers are still running; check the default browser configuration".into());
            }
            match ACTIVE_LAUNCHERS.compare_exchange_weak(
                active,
                active + 1,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => return Ok(Self),
                Err(current) => active = current,
            }
        }
    }
}

impl Drop for LaunchPermit {
    fn drop(&mut self) {
        ACTIVE_LAUNCHERS.fetch_sub(1, Ordering::Relaxed);
    }
}

fn host_command(program: &str, arguments: &[&str], environment: &Environment) -> Command {
    let mut command = Command::new(program);
    command.args(arguments).env_clear().envs(environment);
    if let Some(appdir) = environment.get(std::ffi::OsStr::new("APPDIR")) {
        // These settings belong to our bundled GTK/WebKit, not to Firefox,
        // Chromium, Snap launchers, or the host's gio executable.
        for name in [
            "APPDIR",
            "APPIMAGE",
            "ARGV0",
            "LD_LIBRARY_PATH",
            "LD_PRELOAD",
            "GIO_MODULE_DIR",
            "GIO_EXTRA_MODULES",
            "GI_TYPELIB_PATH",
            "GTK_PATH",
            "GTK_DATA_PREFIX",
            "GTK_EXE_PREFIX",
            "GTK_IM_MODULE_FILE",
            "GDK_PIXBUF_MODULE_FILE",
            "GDK_PIXBUF_MODULEDIR",
            "GSETTINGS_SCHEMA_DIR",
            "WEBKIT_EXEC_PATH",
            "WEBKIT_INJECTED_BUNDLE_PATH",
            "GST_PLUGIN_PATH",
            "GST_PLUGIN_PATH_1_0",
            "GST_PLUGIN_SYSTEM_PATH",
            "GST_PLUGIN_SYSTEM_PATH_1_0",
            "GST_PLUGIN_SCANNER",
            "GST_PLUGIN_SCANNER_1_0",
        ] {
            command.env_remove(name);
        }
        for name in ["PATH", "XDG_DATA_DIRS", "XDG_CONFIG_DIRS"] {
            if let Some(value) = environment.get(std::ffi::OsStr::new(name)) {
                let paths: Vec<_> = std::env::split_paths(value)
                    .filter(|path| !path.starts_with(Path::new(appdir)))
                    .collect();
                if paths.is_empty() {
                    command.env_remove(name);
                } else if let Ok(value) = std::env::join_paths(paths) {
                    command.env(name, value);
                }
            }
        }
    }
    command.stdin(Stdio::null()).stdout(Stdio::null());
    command
}

pub fn open(url: &str) -> Result<(), String> {
    // Some launchers wait for the browser to close. Bound waiting workers,
    // but never kill a browser process merely because its launcher is slow.
    let _permit = LaunchPermit::acquire()?;
    let environment = std::env::vars_os().collect();
    let mut errors = Vec::new();
    for (program, arguments) in [("xdg-open", vec![url]), ("gio", vec!["open", url])] {
        // This runs on a worker, never the GTK event thread. Keep stderr visible.
        match host_command(program, &arguments, &environment).status() {
            Ok(status) if status.success() => return Ok(()),
            Ok(status) => errors.push(format!("{program}: {status}")),
            Err(error) => errors.push(format!("{program}: {error}")),
        }
    }
    Err(errors.join("; "))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn environment(entries: &[(&str, &str)]) -> Environment {
        entries
            .iter()
            .map(|(key, value)| (OsString::from(key), OsString::from(value)))
            .collect()
    }

    #[test]
    fn appimage_paths_are_not_inherited_by_the_browser() {
        let values = environment(&[
            ("APPDIR", "/tmp/Teams AppDir"),
            ("APPIMAGE", "/home/user/Teams.AppImage"),
            ("LD_LIBRARY_PATH", "/tmp/Teams AppDir/usr/lib"),
            ("GIO_MODULE_DIR", "/tmp/Teams AppDir/usr/lib/gio/modules"),
            (
                "GSETTINGS_SCHEMA_DIR",
                "/tmp/Teams AppDir/usr/share/glib-2.0/schemas",
            ),
            ("PATH", "/tmp/Teams AppDir/usr/bin:/home/user/bin:/usr/bin"),
            (
                "XDG_DATA_DIRS",
                "/tmp/Teams AppDir/usr/share:/usr/local/share:/usr/share",
            ),
            ("DISPLAY", ":0"),
            ("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/1000/bus"),
        ]);
        let command = host_command("xdg-open", &["https://example.org/a?b=x&c=y"], &values);
        let result: HashMap<_, _> = command.get_envs().collect();
        for key in [
            "APPDIR",
            "APPIMAGE",
            "LD_LIBRARY_PATH",
            "GIO_MODULE_DIR",
            "GSETTINGS_SCHEMA_DIR",
        ] {
            assert_eq!(result.get(std::ffi::OsStr::new(key)), None, "{key}");
        }
        assert_eq!(
            result[std::ffi::OsStr::new("PATH")],
            Some(std::ffi::OsStr::new("/home/user/bin:/usr/bin"))
        );
        assert_eq!(
            result[std::ffi::OsStr::new("XDG_DATA_DIRS")],
            Some(std::ffi::OsStr::new("/usr/local/share:/usr/share"))
        );
        assert_eq!(
            result[std::ffi::OsStr::new("DISPLAY")],
            Some(std::ffi::OsStr::new(":0"))
        );
        assert_eq!(
            result[std::ffi::OsStr::new("DBUS_SESSION_BUS_ADDRESS")],
            Some(std::ffi::OsStr::new("unix:path=/run/user/1000/bus"))
        );
        assert_eq!(
            command.get_args().collect::<Vec<_>>(),
            [std::ffi::OsStr::new("https://example.org/a?b=x&c=y")]
        );
    }

    #[test]
    fn waiting_browser_launchers_are_bounded_and_release_their_slots() {
        let permits: Vec<_> = (0..4).map(|_| LaunchPermit::acquire().unwrap()).collect();
        assert!(LaunchPermit::acquire().is_err());
        drop(permits);
        assert!(LaunchPermit::acquire().is_ok());
    }

    #[test]
    fn native_non_appimage_launches_keep_their_environment() {
        let values = environment(&[
            ("LD_LIBRARY_PATH", "/custom/browser/lib"),
            ("PATH", "/usr/bin"),
        ]);
        let command = host_command("gio", &["open", "https://example.org"], &values);
        assert_eq!(
            command
                .get_envs()
                .find(|(key, _)| *key == "LD_LIBRARY_PATH")
                .unwrap()
                .1,
            Some(std::ffi::OsStr::new("/custom/browser/lib"))
        );
    }
}
