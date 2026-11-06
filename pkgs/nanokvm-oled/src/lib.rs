//! Drawing on a 128x64 monochrome framebuffer (the `NanoKVM`'s SSD1306 OLED
//! through ssd1307fb, `/dev/fb0`), with text that is checked to fit when
//! the program compiles.
//!
//! Text goes on the screen only through a [`Text`] (fixed text) or a
//! [`Field`] (text of at most `max` glyphs). Their constructors are
//! `const fn`s that panic if the text cannot fit: used in a `const` item,
//! that panic fails the build. A field whose longest text is wider than
//! its place must say so with [`Overflow::Marquee`]: such text scrolls.
//!
//! A marquee holds at the head for [`MARQUEE_HOLD_MS`], moves left one
//! pixel per [`MARQUEE_STEP_MS`] until the tail shows, holds at the tail,
//! then starts again at the head. Its position is a function of the clock
//! and of an anchor time, so a redraw of the screen continues the scroll
//! where it was.
#![forbid(unsafe_code)]

pub const W: i32 = 128;
pub const H: i32 = 64;
const STRIDE: usize = W as usize / 8;
const BYTES: usize = STRIDE * H as usize;

/// Time at the head and at the tail of a marquee.
pub const MARQUEE_HOLD_MS: i64 = 2000;
/// Time per pixel of a marquee: 10 px/s, two 5 px glyphs a second.
pub const MARQUEE_STEP_MS: i64 = 100;

/// A Linux console font (PSF1 or PSF2), parsed at compile time.
pub struct Font {
    glyphs: &'static [u8],
    count: usize,
    bytes: usize,
    row: usize, // bytes per glyph row
    pub height: i32,
    pub width: i32,
}

const fn u32_le(data: &[u8], at: usize) -> usize {
    u32::from_le_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]]) as usize
}

impl Font {
    /// Parses a PSF1 or PSF2 font.
    ///
    /// # Panics
    ///
    /// On a font of another format: in a `const` item, the build fails.
    #[must_use]
    pub const fn psf(data: &'static [u8]) -> Font {
        if data[0] == 0x36 && data[1] == 0x04 {
            // PSF1: magic, mode (bit 0: 512 glyphs), charsize; 8 px wide.
            let (_, glyphs) = data.split_at(4);
            Font {
                glyphs,
                count: if data[2] & 1 == 1 { 512 } else { 256 },
                bytes: data[3] as usize,
                row: 1,
                height: data[3] as i32,
                width: 8,
            }
        } else {
            // PSF2: magic, version, headersize, flags, length, charsize,
            // height, width.
            assert!(u32_le(data, 0) == 0x864a_b572, "unknown font format");
            let (_, glyphs) = data.split_at(u32_le(data, 8));
            #[expect(
                clippy::cast_possible_truncation,
                clippy::cast_possible_wrap,
                reason = "PSF2 glyph sizes are a few pixels"
            )]
            Font {
                glyphs,
                count: u32_le(data, 16),
                bytes: u32_le(data, 20),
                row: u32_le(data, 28).div_ceil(8),
                height: u32_le(data, 24) as i32,
                width: u32_le(data, 28) as i32,
            }
        }
    }

    /// Width of `glyphs` glyphs.
    #[must_use]
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_possible_wrap,
        reason = "screen text is far shorter than i32::MAX glyphs"
    )]
    pub const fn width_of(&self, glyphs: usize) -> i32 {
        glyphs as i32 * self.width
    }
}

/// A 1 bpp image from a binary PBM file (P4), parsed at compile time.
pub struct Bitmap {
    bits: &'static [u8],
    pub width: i32,
    pub height: i32,
}

/// Skips whitespace, then reads a decimal number; returns it and the
/// position after it.
const fn pbm_number(data: &[u8], mut at: usize) -> (usize, usize) {
    while at < data.len() && data[at].is_ascii_whitespace() {
        at += 1;
    }
    assert!(
        at < data.len() && data[at].is_ascii_digit(),
        "a PBM header without its size (comments are not read)"
    );
    let mut n = 0;
    while at < data.len() && data[at].is_ascii_digit() {
        n = n * 10 + (data[at] - b'0') as usize;
        at += 1;
    }
    (n, at)
}

impl Bitmap {
    /// Parses a binary PBM (P4) image; an empty file is no image.
    ///
    /// # Panics
    ///
    /// On another format, or on a file shorter than its size: in a `const`
    /// item, the build fails.
    #[must_use]
    pub const fn pbm(data: &'static [u8]) -> Option<Bitmap> {
        if data.is_empty() {
            return None;
        }
        assert!(
            data.len() > 2 && data[0] == b'P' && data[1] == b'4',
            "not a binary PBM (P4) image"
        );
        let (width, at) = pbm_number(data, 2);
        let (height, at) = pbm_number(data, at);
        // One whitespace byte, then the rows: MSB first, padded to bytes.
        let (_, bits) = data.split_at(at + 1);
        assert!(
            bits.len() >= width.div_ceil(8) * height,
            "a PBM image shorter than its size"
        );
        assert!(
            width <= W as usize && height <= H as usize,
            "a PBM image larger than the screen"
        );
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_possible_wrap,
            reason = "at most the screen's size"
        )]
        let (width, height) = (width as i32, height as i32);
        Some(Bitmap {
            bits,
            width,
            height,
        })
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Align {
    Left,
    Center,
    Right,
}

/// What a [`Field`] does with text wider than its place.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Overflow {
    /// Its longest text fits: checked when the program compiles.
    Fit,
    /// Text wider than the place scrolls (see the crate documentation).
    Marquee,
}

/// Fixed text in `[x, x + w)`, checked to fit when the program compiles.
pub struct Text {
    font: &'static Font,
    x: i32,
    y: i32,
    w: i32,
    align: Align,
    ink: bool,
    content: &'static str,
}

impl Text {
    /// `ink` false draws dark text (on a lit bar).
    ///
    /// # Panics
    ///
    /// If the text does not fit in `w`: in a `const` item, the build fails.
    #[must_use]
    pub const fn new(
        font: &'static Font,
        (x, y, w): (i32, i32, i32),
        align: Align,
        ink: bool,
        content: &'static str,
    ) -> Text {
        assert!(
            font.width_of(content.len()) <= w,
            "the text does not fit: shorten it, widen its place, or make it a Field with Overflow::Marquee"
        );
        Text {
            font,
            x,
            y,
            w,
            align,
            ink,
            content,
        }
    }
}

/// A place for text of at most `max` glyphs in `[x, x + w)`. A `lead` of
/// pixels before the text (an icon or a label of the caller) counts in the
/// width and in the alignment.
#[derive(Clone, Copy)]
pub struct Field {
    font: &'static Font,
    x: i32,
    y: i32,
    w: i32,
    align: Align,
    ink: bool,
    max: usize,
    lead: i32,
    overflow: Overflow,
}

impl Field {
    /// `ink` false draws dark text (on a lit bar).
    ///
    /// # Panics
    ///
    /// If `overflow` is [`Overflow::Fit`] and `lead` and `max` glyphs do
    /// not fit in `w`: in a `const` item, the build fails.
    #[must_use]
    pub const fn new(
        font: &'static Font,
        (x, y, w): (i32, i32, i32),
        align: Align,
        ink: bool,
        (max, lead): (usize, i32),
        overflow: Overflow,
    ) -> Field {
        assert!(
            !matches!(overflow, Overflow::Fit) || lead + font.width_of(max) <= w,
            "the field's longest text does not fit: give it Overflow::Marquee, \
             or split its text across the redraws of the screen"
        );
        Field {
            font,
            x,
            y,
            w,
            align,
            ink,
            max,
            lead,
            overflow,
        }
    }

    /// The same field at another `x` (for text placed after something of
    /// variable width); its width and its check do not change.
    #[must_use]
    pub const fn at(self, x: i32) -> Field {
        Field { x, ..self }
    }
}

struct Marquee {
    font: &'static Font,
    x: i32,
    y: i32,
    w: i32,
    ink: bool,
    anchor_ms: i64,
    text: String,
}

impl Marquee {
    fn offset(&self, now_ms: i64) -> i32 {
        marquee_offset(
            i64::from(self.font.width_of(self.text.len()) - self.w),
            now_ms - self.anchor_ms,
        )
    }
}

/// The offset of a marquee that is `over` pixels too wide, `since_ms`
/// after its anchor.
#[must_use]
pub fn marquee_offset(over: i64, since_ms: i64) -> i32 {
    if over <= 0 {
        return 0;
    }
    let period = 2 * MARQUEE_HOLD_MS + over * MARQUEE_STEP_MS;
    let t = since_ms.rem_euclid(period);
    let px = ((t - MARQUEE_HOLD_MS) / MARQUEE_STEP_MS).clamp(0, over);
    i32::try_from(px).unwrap_or(0)
}

/// A frame: what [`Screen::compose`] shows is the drawing since
/// [`Screen::clear`] with each marquee at its position for the time.
pub struct Screen {
    base: [u8; BYTES],
    frame: [u8; BYTES],
    marquees: Vec<Marquee>,
}

impl Default for Screen {
    fn default() -> Self {
        Screen {
            base: [0; BYTES],
            frame: [0; BYTES],
            marquees: Vec::new(),
        }
    }
}

/// ssd1307fb's layout: pixel (x, y) is bit x % 8 (LSB first) of byte
/// y * 16 + x / 8.
fn set(buf: &mut [u8; BYTES], x: i32, y: i32, on: bool) {
    if !(0..W).contains(&x) || !(0..H).contains(&y) {
        return;
    }
    #[expect(clippy::cast_sign_loss, reason = "x and y are on the screen")]
    let (i, bit) = (y as usize * STRIDE + x as usize / 8, 1u8 << (x % 8));
    if on {
        buf[i] |= bit;
    } else {
        buf[i] &= !bit;
    }
}

/// Draws `text` at (x, y), only the pixels in `[clip_x, clip_x + clip_w)`.
fn glyphs(
    buf: &mut [u8; BYTES],
    font: &Font,
    (x, y): (i32, i32),
    text: &str,
    ink: bool,
    (clip_x, clip_w): (i32, i32),
) {
    let row = font.row;
    let mut gx = x;
    for c in text.bytes() {
        let c = if usize::from(c) < font.count {
            usize::from(c)
        } else {
            usize::from(b'?')
        };
        let glyph = &font.glyphs[c * font.bytes..][..font.bytes];
        for j in 0..font.height {
            for i in 0..font.width {
                let px = gx + i;
                #[expect(clippy::cast_sign_loss, reason = "glyph coordinates are not negative")]
                let lit = glyph[j as usize * row + i as usize / 8] & (0x80 >> (i % 8)) != 0;
                if lit && px >= clip_x && px < clip_x + clip_w {
                    set(buf, px, y + j, ink);
                }
            }
        }
        gx += font.width;
    }
}

fn aligned(align: Align, x: i32, w: i32, content: i32) -> i32 {
    match align {
        Align::Left => x,
        Align::Center => x + (w - content) / 2,
        Align::Right => x + w - content,
    }
}

impl Screen {
    /// Starts a new drawing: all pixels off, no marquees.
    pub fn clear(&mut self) {
        self.base = [0; BYTES];
        self.marquees.clear();
    }

    pub fn px(&mut self, x: i32, y: i32, on: bool) {
        set(&mut self.base, x, y, on);
    }

    pub fn fill(&mut self, (x, y, w, h): (i32, i32, i32, i32), on: bool) {
        for j in y..y + h {
            for i in x..x + w {
                self.px(i, j, on);
            }
        }
    }

    pub fn frame(&mut self, (x, y, w, h): (i32, i32, i32, i32)) {
        self.fill((x, y, w, 1), true);
        self.fill((x, y + h - 1, w, 1), true);
        self.fill((x, y, 1, h), true);
        self.fill((x + w - 1, y, 1, h), true);
    }

    /// An 8x8 icon: one byte per row, MSB on the left.
    pub fn icon(&mut self, x: i32, y: i32, bits: &[u8; 8], on: bool) {
        for (j, row) in (0..).zip(bits) {
            for i in 0..8 {
                if row & (0x80 >> i) != 0 {
                    self.px(x + i, y + j, on);
                }
            }
        }
    }

    /// The lit pixels of `b` with their top left at (x, y).
    pub fn bitmap(&mut self, x: i32, y: i32, b: &Bitmap, on: bool) {
        #[expect(clippy::cast_sign_loss, reason = "the width is not negative")]
        let row = (b.width as usize).div_ceil(8);
        for (j, line) in (0..b.height).zip(b.bits.chunks(row)) {
            for i in 0..b.width {
                #[expect(clippy::cast_sign_loss, reason = "i is not negative")]
                let lit = line[i as usize / 8] & (0x80 >> (i % 8)) != 0;
                if lit {
                    self.px(x + i, y + j, on);
                }
            }
        }
    }

    /// A bar gauge: an outline with the share `frac` (0..1) filled.
    pub fn gauge(&mut self, (x, y, w, h): (i32, i32, i32, i32), frac: f64) {
        self.frame((x, y, w, h));
        #[expect(clippy::cast_possible_truncation, reason = "at most the gauge's width")]
        let lit = (f64::from(w - 4) * frac.clamp(0.0, 1.0)).round() as i32;
        self.fill((x + 2, y + 2, lit, h - 4), true);
    }

    /// A line from (x0, y0) to (x1, y1), `w` pixels thick (Bresenham).
    pub fn line(&mut self, (mut x0, mut y0): (i32, i32), (x1, y1): (i32, i32), w: i32) {
        let (dx, sx) = ((x1 - x0).abs(), if x0 < x1 { 1 } else { -1 });
        let (dy, sy) = (-(y1 - y0).abs(), if y0 < y1 { 1 } else { -1 });
        let mut err = dx + dy;
        loop {
            self.fill((x0 - w / 2, y0 - w / 2, w, w), true);
            if x0 == x1 && y0 == y1 {
                break;
            }
            let e2 = 2 * err;
            if e2 >= dy {
                err += dy;
                x0 += sx;
            }
            if e2 <= dx {
                err += dx;
                y0 += sy;
            }
        }
    }

    pub fn text(&mut self, t: &Text) {
        let x = aligned(t.align, t.x, t.w, t.font.width_of(t.content.len()));
        glyphs(
            &mut self.base,
            t.font,
            (x, t.y),
            t.content,
            t.ink,
            (t.x, t.w),
        );
    }

    /// Puts `text` in the field; text past the field's `max` glyphs is cut.
    /// Text of a marquee field that does not fit scrolls from `anchor_ms`
    /// (a time of the clock that [`Screen::compose`] gets).
    pub fn put(&mut self, f: &Field, text: &str, anchor_ms: i64) {
        let text = &text[..text.len().min(f.max)];
        let width = f.font.width_of(text.len());
        if f.overflow == Overflow::Marquee && width > f.w {
            self.marquees.push(Marquee {
                font: f.font,
                x: f.x,
                y: f.y,
                w: f.w,
                ink: f.ink,
                anchor_ms,
                text: text.to_owned(),
            });
            return;
        }
        let x = aligned(f.align, f.x, f.w, width);
        glyphs(&mut self.base, f.font, (x, f.y), text, f.ink, (f.x, f.w));
    }

    /// Puts `text` after `lead` pixels (at most the field's `lead`), and
    /// aligns both together. Returns where the lead starts.
    pub fn put_after(&mut self, f: &Field, lead: i32, text: &str) -> i32 {
        let text = &text[..text.len().min(f.max)];
        let lead = lead.min(f.lead);
        let x = aligned(f.align, f.x, f.w, lead + f.font.width_of(text.len()));
        glyphs(
            &mut self.base,
            f.font,
            (x + lead, f.y),
            text,
            f.ink,
            (f.x, f.w),
        );
        x
    }

    /// Whether frames between redraws can differ.
    #[must_use]
    pub fn animated(&self) -> bool {
        !self.marquees.is_empty()
    }

    /// The frame at `now_ms`: the drawing with each marquee at its offset.
    pub fn compose(&mut self, now_ms: i64) -> &[u8] {
        self.frame = self.base;
        for m in &self.marquees {
            glyphs(
                &mut self.frame,
                m.font,
                (m.x - m.offset(now_ms), m.y),
                &m.text,
                m.ink,
                (m.x, m.w),
            );
        }
        &self.frame
    }
}

/// `frame` as a PBM image (P4; rows MSB first, the framebuffer's LSB first).
#[must_use]
pub fn pbm(frame: &[u8]) -> Vec<u8> {
    let mut out = format!("P4\n{W} {H}\n").into_bytes();
    out.extend(frame.iter().map(|b| b.reverse_bits()));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // A PSF2 font of 2 glyphs, 3x2 px: glyph 1 has its top-left pixel.
    const TINY: Font = Font::psf(&[
        0x72, 0xb5, 0x4a, 0x86, 0, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0,
        0, 0, 3, 0, 0, 0, 0, 0, 0x80, 0,
    ]);

    #[test]
    fn pbm_image() {
        const B: Option<Bitmap> = Bitmap::pbm(b"P4\n9 2\n\x80\x80\x00\x00");
        let b = B.unwrap();
        assert_eq!((b.width, b.height), (9, 2));
        let mut s = Screen::default();
        s.bitmap(3, 0, &b, true);
        let f = s.compose(0);
        // Row 0: the first and the ninth pixel; row 1: none.
        assert_eq!((f[0], f[1], f[16], f[17]), (1 << 3, 1 << 3, 0, 0));
        assert!(Bitmap::pbm(b"").is_none());
    }

    #[test]
    fn psf2_header() {
        assert_eq!(
            (TINY.width, TINY.height, TINY.count, TINY.bytes),
            (3, 2, 2, 2)
        );
    }

    #[test]
    fn marquee_holds_scrolls_holds_returns() {
        let over = 7;
        let step = MARQUEE_STEP_MS;
        assert_eq!(marquee_offset(over, 0), 0);
        assert_eq!(marquee_offset(over, MARQUEE_HOLD_MS - 1), 0);
        assert_eq!(marquee_offset(over, MARQUEE_HOLD_MS + step), 1);
        assert_eq!(marquee_offset(over, MARQUEE_HOLD_MS + 7 * step), 7);
        assert_eq!(marquee_offset(over, 2 * MARQUEE_HOLD_MS + 7 * step - 1), 7);
        // The next period starts at the head again.
        assert_eq!(marquee_offset(over, 2 * MARQUEE_HOLD_MS + 7 * step), 0);
        assert_eq!(marquee_offset(0, 12_345), 0);
    }

    #[test]
    fn marquee_continues_across_redraws() {
        // A redraw registers the marquee again with the same anchor; the
        // frame just after it shows the same offset as the one just before.
        let field = Field::new(
            &TINY,
            (0, 0, 6),
            Align::Left,
            true,
            (8, 0),
            Overflow::Marquee,
        );
        let mut s = Screen::default();
        s.put(&field, "\x01\x01\x01\x01", 0);
        let before = s.compose(MARQUEE_HOLD_MS + 4 * MARQUEE_STEP_MS).to_vec();
        s.clear();
        s.put(&field, "\x01\x01\x01\x01", 0);
        assert_eq!(
            s.compose(MARQUEE_HOLD_MS + 4 * MARQUEE_STEP_MS),
            &before[..]
        );
    }

    #[test]
    fn marquee_is_clipped_to_its_field() {
        let field = Field::new(
            &TINY,
            (3, 0, 6),
            Align::Left,
            true,
            (8, 0),
            Overflow::Marquee,
        );
        let mut s = Screen::default();
        s.put(&field, "\x01\x01\x01\x01", 0);
        // At offset 0 the glyphs start at x = 3, 6, 9 (cut), 12 (cut).
        let f = s.compose(0);
        let lit: Vec<usize> = (0..128)
            .filter(|&x| f[x / 8] & (1 << (x % 8)) != 0)
            .collect();
        assert_eq!(lit, vec![3, 6]);
    }

    #[test]
    fn fitting_text_of_a_marquee_field_does_not_scroll() {
        let field = Field::new(
            &TINY,
            (0, 0, 6),
            Align::Left,
            true,
            (8, 0),
            Overflow::Marquee,
        );
        let mut s = Screen::default();
        s.put(&field, "\x01\x01", 0);
        assert!(!s.animated());
    }
}
