//! nanokvm-oled: the status screen of the `NanoKVM`'s 128x64 OLED.
//!
//!   nanokvm-oled [FB]                redraw FB (default /dev/fb0) every 5 s
//!   nanokvm-oled --pbm FILE          one frame as a PBM image (preview)
//!   nanokvm-oled --splash-pbm FILE   the splash as a PBM image
//!   nanokvm-oled --logo-pbm FILE     the site's logo as a PBM image
//!
//! Reads /proc, /sys, the kernel command line and nanokvm-ab's runtime
//! flags; never the card. Every `write()` to ssd1307fb's framebuffer goes to
//! the panel. Between the 5 s redraws, only the frames of scrolling text
//! (a marquee) are written, and only when they change.
#![forbid(unsafe_code)]

use std::f64::consts::PI;
use std::fs;
use std::net::Ipv6Addr;
use std::path::Path;

use nanokvm_oled::{Align, Bitmap, Field, Font, H, MARQUEE_STEP_MS, Overflow, Screen, Text, W};
use nix::ifaddrs::getifaddrs;
use nix::sys::time::TimeSpec;
use nix::time::{ClockId, ClockNanosleepFlags, clock_gettime, clock_nanosleep};

const SMALL: Font = Font::psf(include_bytes!(env!("NANOKVM_OLED_FONT_SMALL")));
const BIG: Font = Font::psf(include_bytes!(env!("NANOKVM_OLED_FONT_BIG")));
const VERSION: &str = match option_env!("NANOKVM_VERSION") {
    Some(v) => v,
    None => "dev",
};
// Site images (modules/display.nix), rasterised by the build; an empty
// file is none. The logo is shown after the splash; the header icon takes
// the place of the project's mark in the header bar.
const LOGO: Option<Bitmap> = Bitmap::pbm(include_bytes!(env!("NANOKVM_OLED_LOGO")));
const HEADER_ICON: Option<Bitmap> = Bitmap::pbm(include_bytes!(env!("NANOKVM_OLED_HEADER_ICON")));
const _: () = {
    if let Some(b) = &HEADER_ICON {
        // Left of the hostname (x = 13), inside the bar (y = 1..10).
        assert!(
            b.width <= 10 && b.height <= 9,
            "the header icon is larger than 10x9"
        );
    }
};
const IFACE: &str = "eth0";
const REDRAW_MS: i64 = 5000;

// 8x8 icons, one byte per row, MSB on the left.
const ICON_ETH: [u8; 8] = [0x00, 0x7e, 0x42, 0x5a, 0x5a, 0x42, 0x7e, 0x24];
const ICON_HEART: [u8; 8] = [0x00, 0x66, 0xff, 0xff, 0x7e, 0x3c, 0x18, 0x00];
const ICON_HOURGLASS: [u8; 8] = [0x7e, 0x42, 0x24, 0x18, 0x18, 0x24, 0x5a, 0x7e];
const ICON_CHECK: [u8; 8] = [0x00, 0x01, 0x03, 0x06, 0x8c, 0xd8, 0x70, 0x20];
const ICON_CROSS: [u8; 8] = [0x00, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x00];
const ICON_CLOCK: [u8; 8] = [0x3c, 0x42, 0x91, 0x91, 0x9d, 0x81, 0x42, 0x3c];
// The project's mark in miniature: a six-armed asterisk (7x7).
const ICON_FLAKE: [u8; 8] = [0x10, 0x92, 0x54, 0x38, 0x54, 0x92, 0x10, 0x00];

// The layout. Each text has its place here; the build fails if the
// longest text of a place does not fit in it.

// Header bar (dark text): the hostname, then "SLOT A" left of the state
// icon. A hostname (up to 64 characters) longer than its place scrolls.
const HOST: Field = Field::new(
    &SMALL,
    (13, 2, 68),
    Align::Left,
    false,
    (64, 0),
    Overflow::Marquee,
);
const SLOT: Field = Field::new(
    &SMALL,
    (86, 2, 30),
    Align::Right,
    false,
    (6, 0),
    Overflow::Fit,
);
// Large clock with its icon or zone label (the lead) in front, centred
// together. Uptime has at most 13 glyphs ("1y364d23h59m").
const CLOCK: Field = Field::new(
    &BIG,
    (0, 12, W),
    Align::Center,
    true,
    (13, 17),
    Overflow::Fit,
);
const ZONE: Field = Field::new(
    &SMALL,
    (0, 16, 15),
    Align::Left,
    true,
    (3, 0),
    Overflow::Fit,
);
// Link speed ("10000M", "down") and health.
const LINK: Field = Field::new(
    &SMALL,
    (13, 30, 51),
    Align::Left,
    true,
    (10, 0),
    Overflow::Fit,
);
const HEALTH: Field = Field::new(
    &SMALL,
    (77, 30, 49),
    Align::Left,
    true,
    (7, 0),
    Overflow::Fit,
);
const TEMP_LABEL: Text = Text::new(&SMALL, (2, 39, 22), Align::Left, true, "TEMP");
const TEMP: Field = Field::new(
    &SMALL,
    (98, 39, 28),
    Align::Right,
    true,
    (5, 0),
    Overflow::Fit,
);
const CPU_LABEL: Text = Text::new(&SMALL, (2, 48, 22), Align::Left, true, "CPU");
const CPU: Field = Field::new(
    &SMALL,
    (98, 48, 28),
    Align::Right,
    true,
    (4, 0),
    Overflow::Fit,
);
// The bottom row: an IPv4 address ("IPv4 " and 15), an IPv6 address (up
// to 39) or a MAC address ("MAC " and 17). A long IPv6 address scrolls.
const BOTTOM: Field = Field::new(
    &SMALL,
    (2, 56, W - 4),
    Align::Center,
    true,
    (39, 0),
    Overflow::Marquee,
);
// Splash.
const SPLASH_NAME: Text = Text::new(&BIG, (0, 29, W), Align::Center, true, "nixos-nanokvm");
const SPLASH_BUILD: Field = Field::new(
    &SMALL,
    (0, 50, W),
    Align::Center,
    true,
    ("mixos  A/B  ".len() + VERSION.len(), 0),
    Overflow::Fit,
);

/* ---- readings ------------------------------------------------------------ */

fn read_line(path: impl AsRef<Path>) -> Option<String> {
    let s = fs::read_to_string(path).ok()?;
    Some(s.lines().next().unwrap_or("").to_owned())
}

/// CPU utilisation (0..1) since the previous call, from /proc/stat's
/// aggregate line: 1 - (idle + iowait) / total.
#[derive(Default)]
struct Cpu {
    total: u64,
    idle: u64,
}

impl Cpu {
    fn busy(&mut self) -> f64 {
        let Some(line) = read_line("/proc/stat") else {
            return 0.0;
        };
        let v: Vec<u64> = line
            .split_whitespace()
            .skip(1)
            .take(8)
            .filter_map(|f| f.parse().ok())
            .collect();
        if v.len() < 4 {
            return 0.0;
        }
        let total: u64 = v.iter().sum();
        let idle = v[3] + v.get(4).copied().unwrap_or(0);
        let busy = if total > self.total {
            #[expect(clippy::cast_precision_loss, reason = "a share")]
            let share = (idle - self.idle) as f64 / (total - self.total) as f64;
            1.0 - share
        } else {
            0.0
        };
        (self.total, self.idle) = (total, idle);
        busy
    }
}

fn cmdline(key: &str) -> String {
    read_line("/proc/cmdline")
        .unwrap_or_default()
        .split_whitespace()
        .find_map(|w| w.strip_prefix(key)?.strip_prefix('=').map(str::to_owned))
        .unwrap_or_default()
}

fn ipv4() -> Option<String> {
    getifaddrs().ok()?.find_map(|a| {
        let addr = a.address?;
        (a.interface_name == IFACE).then(|| addr.as_sockaddr_in().map(|s| s.ip().to_string()))?
    })
}

/// The IPv6 link-local address of the interface (reachable over a direct
/// cable: `ssh root@fe80::...%<interface>`), from `/proc/net/if_inet6`.
fn ipv6_link_local() -> Option<String> {
    let table = fs::read_to_string("/proc/net/if_inet6").ok()?;
    table.lines().find_map(|l| {
        let f: Vec<&str> = l.split_whitespace().collect();
        // address, index, prefix length, scope (0x20: link), flags, name
        if f.len() < 6 || f[5] != IFACE || f[3] != "20" || f[0].len() != 32 {
            return None;
        }
        let bits = u128::from_str_radix(f[0], 16).ok()?;
        Some(Ipv6Addr::from(bits).to_string())
    })
}

/// ntpd's event script keeps this file while the clock is synchronised
/// (modules/board.nix); it is on a tmpfs, so a reboot clears it.
fn ntp_synced() -> bool {
    Path::new("/run/ntp-synced").exists()
}

/// The clock that is shown: wall time once NTP has set it, uptime before.
fn display_clock() -> ClockId {
    if ntp_synced() {
        ClockId::CLOCK_REALTIME
    } else {
        ClockId::CLOCK_BOOTTIME
    }
}

fn clock_ms(id: ClockId) -> i64 {
    clock_gettime(id).map_or(0, |t| t.tv_sec() * 1000 + t.tv_nsec() / 1_000_000)
}

/* ---- time ---------------------------------------------------------------- */

/// Uptime with units, not colons, so it never reads as a time of day; only
/// the nonzero ones ("3d2h5s"). Past a year the seconds give way to the
/// years, so it stays within 13 glyphs.
fn uptime_text(s: i64) -> String {
    let d = s / 86400;
    let v = [
        d / 365,
        d % 365,
        s % 86400 / 3600,
        s % 3600 / 60,
        if d >= 365 { 0 } else { s % 60 },
    ];
    let mut out = String::new();
    for (n, unit) in v.iter().zip("ydhms".chars()).filter(|(n, _)| **n != 0) {
        out.push_str(&n.to_string());
        out.push(unit);
    }
    if out.is_empty() { "0s".to_owned() } else { out }
}

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The year of a day since 1970-01-01.
fn year_of(days: i64) -> i64 {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    yoe + era * 400 + i64::from(mp >= 10)
}

/// The day of the `n`th Sunday (1-based) of a month.
fn nth_sunday(y: i64, m: i64, n: i64) -> i64 {
    let first = days_from_civil(y, m, 1);
    let to_sunday = (7 - (first + 4).rem_euclid(7)) % 7; // 1970-01-01 was a Thursday
    first + to_sunday + 7 * (n - 1)
}

/// US Eastern time (EST5EDT,M3.2.0,M11.1.0): the offset from UTC in
/// seconds and the zone's abbreviation at `utc` (seconds since the epoch).
/// Daylight time runs from 02:00 EST on the second Sunday of March to
/// 02:00 EDT on the first Sunday of November.
fn eastern(utc: i64) -> (i64, &'static str) {
    let y = year_of(utc.div_euclid(86400));
    let start = nth_sunday(y, 3, 2) * 86400 + 7 * 3600;
    let end = nth_sunday(y, 11, 1) * 86400 + 6 * 3600;
    if (start..end).contains(&utc) {
        (-4 * 3600, "EDT")
    } else {
        (-5 * 3600, "EST")
    }
}

fn hms(secs: i64) -> String {
    let s = secs.rem_euclid(86400);
    format!("{:02}:{:02}:{:02}", s / 3600, s % 3600 / 60, s % 60)
}

/* ---- screens ------------------------------------------------------------- */

fn draw(s: &mut Screen, cpu: &mut Cpu, state_dir: &Path) {
    s.clear();
    let (healthy, on_trial) = header(s, state_dir);
    // The rows rotate on the shown clock's 5 s boundaries.
    let tick = clock_ms(display_clock()) / REDRAW_MS;
    clock_row(s, tick);
    for x in (0..W).step_by(2) {
        s.px(x, 28, true);
    }

    // Link and health.
    let net = Path::new("/sys/class/net").join(IFACE);
    let up = read_line(net.join("operstate")).as_deref() == Some("up");
    let speed = read_line(net.join("speed")).filter(|v| !v.is_empty() && !v.starts_with('-'));
    let link = match (up, speed) {
        (false, _) => "down".to_owned(),
        (true, None) => "up".to_owned(),
        (true, Some(v)) => format!("{v}M"),
    };
    s.icon(2, 30, &ICON_ETH, true);
    s.put(&LINK, &link, 0);
    s.icon(66, 30, &ICON_HEART, true);
    let health = match (on_trial, healthy) {
        (true, _) => "trial",
        (false, true) => "healthy",
        (false, false) => "booting",
    };
    s.put(&HEALTH, health, 0);

    // SoC temperature, 20..90 C.
    let temp = read_line("/sys/class/thermal/thermal_zone0/temp")
        .and_then(|t| t.parse::<f64>().ok())
        .unwrap_or(0.0)
        / 1000.0;
    s.text(&TEMP_LABEL);
    s.gauge((24, 39, 72, 8), (temp - 20.0) / 70.0);
    s.put(&TEMP, &format!("{temp:.0}C"), 0);

    // CPU utilisation since the previous redraw.
    let busy = cpu.busy();
    s.text(&CPU_LABEL);
    s.gauge((24, 48, 72, 8), busy);
    s.put(&CPU, &format!("{:.0}%", busy * 100.0), 0);

    bottom_row(s, &net, tick);
}

/// The lit bar: the hostname left, the slot and its state right. Returns
/// whether the slot is healthy, and whether it runs on trial.
fn header(s: &mut Screen, state_dir: &Path) -> (bool, bool) {
    s.fill((0, 0, W, 11), true);
    let healthy = state_dir.join("healthy").exists();
    let on_trial = cmdline("nanokvm.trial") == "1" && !state_dir.join("committed").exists();
    let letter = cmdline("nanokvm.slot")
        .bytes()
        .next()
        .map_or('?', |c| char::from(c.to_ascii_uppercase()));
    s.put(&SLOT, &format!("SLOT {letter}"), 0);
    let state = match (on_trial, healthy) {
        (true, _) => &ICON_HOURGLASS,
        (false, true) => &ICON_CHECK,
        (false, false) => &ICON_CROSS,
    };
    s.icon(W - 11, 1, state, false);
    match &HEADER_ICON {
        // Lit on a dark tile (x = 1..11), as the logo shows on the screen:
        // a dark mark on the lit bar is hard to read.
        Some(b) => {
            s.fill((1, 0, 11, 11), false);
            s.bitmap(2, 1, b, true);
        }
        None => s.icon(2, 1, &ICON_FLAKE, false),
    }
    // Anchored at the clock's zero: the 5 s redraws continue its scroll.
    let host = read_line("/proc/sys/kernel/hostname").unwrap_or_default();
    s.put(&HOST, &host, 0);
    (healthy, on_trial)
}

/// The large clock, 5 s each: uptime (clock icon), then UTC and US Eastern
/// time once NTP has set the clock (labelled in small type).
fn clock_row(s: &mut Screen, tick: i64) {
    let uptime: f64 = read_line("/proc/uptime")
        .and_then(|u| u.split_whitespace().next()?.parse().ok())
        .unwrap_or(0.0);
    let utc = clock_ms(ClockId::CLOCK_REALTIME) / 1000;
    match if ntp_synced() { tick % 3 } else { 0 } {
        0 => {
            #[expect(clippy::cast_possible_truncation, reason = "whole seconds of uptime")]
            let x = s.put_after(&CLOCK, 11, &uptime_text(uptime as i64));
            s.icon(x, 16, &ICON_CLOCK, true);
        }
        phase => {
            let (offset, zone) = if phase == 1 { (0, "UTC") } else { eastern(utc) };
            let lead = SMALL.width_of(zone.len()) + 2;
            let x = s.put_after(&CLOCK, lead, &hms(utc + offset));
            s.put(&ZONE.at(x), zone, 0);
        }
    }
}

/// The bottom row, 5 s each, through whichever of these exist. A row that
/// scrolls starts at its head each time it is shown.
fn bottom_row(s: &mut Screen, net: &Path, tick: i64) {
    let mac = read_line(net.join("address")).filter(|m| !m.is_empty());
    let rows: Vec<String> = [
        ipv4().map(|a| format!("IPv4 {a}")),
        ipv6_link_local(),
        mac.map(|m| format!("MAC {m}")),
    ]
    .into_iter()
    .flatten()
    .collect();
    let Some(n) = i64::try_from(rows.len()).ok().filter(|&n| n > 0) else {
        return;
    };
    let row = usize::try_from(tick.rem_euclid(n)).map_or("", |i| rows[i].as_str());
    s.put(&BOTTOM, row, tick * REDRAW_MS);
}

/// The project's mark: a six-armed snowflake (after Nix's), radius r.
fn snowflake(s: &mut Screen, (cx, cy): (i32, i32), r: f64) {
    #[expect(clippy::cast_possible_truncation, reason = "coordinates on the screen")]
    let at = |x: i32, y: i32, len: f64, a: f64| {
        (
            (f64::from(x) + len * a.cos()).round() as i32,
            (f64::from(y) - len * a.sin()).round() as i32,
        )
    };
    for k in 0..6 {
        let a = PI / 2.0 + f64::from(k) * PI / 3.0;
        s.line((cx, cy), at(cx, cy, r, a), 2);
        // A branch pair at 55% of the arm, angled 60 degrees off it.
        let (bx, by) = at(cx, cy, 0.55 * r, a);
        for side in [-1.0, 1.0] {
            s.line((bx, by), at(bx, by, 0.35 * r, a + side * PI / 3.0), 1);
        }
    }
}

/// Shown while the service starts: the logo, the project name and the
/// build's revision.
fn splash(s: &mut Screen) {
    s.clear();
    snowflake(s, (W / 2, 13), 12.0);
    s.text(&SPLASH_NAME);
    s.put(&SPLASH_BUILD, &format!("mixos  A/B  {VERSION}"), 0);
}

/// The site's logo, centred, if the build has one.
fn logo(s: &mut Screen) -> bool {
    let Some(logo) = &LOGO else { return false };
    s.clear();
    s.bitmap((W - logo.width) / 2, (H - logo.height) / 2, logo, true);
    true
}

fn show(dev: &str, frame: &[u8]) {
    if let Err(e) = fs::write(dev, frame) {
        eprintln!("nanokvm-oled: {dev}: {e}");
    }
}

fn sleep_until(id: ClockId, ms: i64) {
    let t = TimeSpec::new(ms / 1000, (ms % 1000) * 1_000_000);
    while clock_nanosleep(id, ClockNanosleepFlags::TIMER_ABSTIME, &t)
        == Err(nix::errno::Errno::EINTR)
    {}
}

fn main() {
    let state_dir =
        std::env::var("NANOKVM_AB_STATE_DIR").unwrap_or_else(|_| "/run/nanokvm-ab".to_owned());
    let state_dir = Path::new(&state_dir);
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut screen = Screen::default();
    let mut cpu = Cpu::default();
    match args.as_slice() {
        [flag, file] if flag == "--pbm" => {
            cpu.busy(); // a baseline, so the frame shows a real share
            std::thread::sleep(std::time::Duration::from_millis(500));
            draw(&mut screen, &mut cpu, state_dir);
            let frame = screen.compose(clock_ms(display_clock()));
            std::process::exit(i32::from(
                fs::write(file, nanokvm_oled::pbm(frame)).is_err(),
            ));
        }
        [flag, file] if flag == "--splash-pbm" => {
            splash(&mut screen);
            std::process::exit(i32::from(
                fs::write(file, nanokvm_oled::pbm(screen.compose(0))).is_err(),
            ));
        }
        [flag, file] if flag == "--logo-pbm" => {
            logo(&mut screen);
            std::process::exit(i32::from(
                fs::write(file, nanokvm_oled::pbm(screen.compose(0))).is_err(),
            ));
        }
        _ => {}
    }
    let dev = args.first().map_or("/dev/fb0", String::as_str);
    splash(&mut screen);
    show(dev, screen.compose(0));
    cpu.busy();
    std::thread::sleep(std::time::Duration::from_secs(3));
    if logo(&mut screen) {
        show(dev, screen.compose(0));
        std::thread::sleep(std::time::Duration::from_secs(3));
    }
    // Redraw on every multiple of 5 s of the clock that is shown, so the
    // clock reads :00 or :05 and the rotating rows change with it. Between
    // redraws, a marquee moves one pixel per step.
    let mut shown: Option<Vec<u8>> = None;
    loop {
        let id = display_clock();
        draw(&mut screen, &mut cpu, state_dir);
        let redraw_ms = (clock_ms(id) / REDRAW_MS + 1) * REDRAW_MS;
        loop {
            let frame = screen.compose(clock_ms(id));
            if shown.as_deref() != Some(frame) {
                show(dev, frame);
                shown = Some(frame.to_vec());
            }
            let next = if screen.animated() {
                ((clock_ms(id) / MARQUEE_STEP_MS + 1) * MARQUEE_STEP_MS).min(redraw_ms)
            } else {
                redraw_ms
            };
            sleep_until(id, next);
            if next == redraw_ms {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uptime_units() {
        assert_eq!(uptime_text(0), "0s");
        assert_eq!(uptime_text(3 * 86400 + 2 * 3600 + 5), "3d2h5s");
        // Past a year the seconds give way to the years.
        assert_eq!(uptime_text(365 * 86400 + 59), "1y");
        assert_eq!(
            uptime_text(729 * 86400 + 23 * 3600 + 59 * 60 + 59),
            "1y364d23h59m"
        );
    }

    #[test]
    fn eastern_daylight_time_boundaries() {
        // 2026: daylight time from 2026-03-08 07:00 UTC to 2026-11-01 06:00 UTC.
        let start = days_from_civil(2026, 3, 8) * 86400 + 7 * 3600;
        let end = days_from_civil(2026, 11, 1) * 86400 + 6 * 3600;
        assert_eq!(eastern(start - 1).1, "EST");
        assert_eq!(eastern(start).1, "EDT");
        assert_eq!(eastern(end - 1).1, "EDT");
        assert_eq!(eastern(end), (-5 * 3600, "EST"));
        assert_eq!(year_of(days_from_civil(2026, 12, 31)), 2026);
        assert_eq!(year_of(days_from_civil(2027, 1, 1)), 2027);
    }

    #[test]
    fn hms_of_a_utc_time() {
        // 2026-11-06 21:10:08 UTC.
        assert_eq!(
            hms(days_from_civil(2026, 11, 6) * 86400 + 21 * 3600 + 10 * 60 + 8),
            "21:10:08"
        );
        assert_eq!(hms(-1), "23:59:59");
    }
}
