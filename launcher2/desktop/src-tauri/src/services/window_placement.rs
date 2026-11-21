//! Where Coco's window opens: centered on the screen the pointer is on, inside its usable area
//! (the taskbar excluded), and smaller than its default size when that screen cannot hold it.

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// Room left around the window on a screen too small for it, so its edges stay reachable.
const MARGIN: f64 = 0.94;

/// The window's place on `work`: its size, shrunk evenly to fit if needed, centered.
pub fn centered(work: Rect, width: u32, height: u32, min_width: u32, min_height: u32) -> Rect {
    let fit = (f64::from(work.width) * MARGIN / f64::from(width.max(1)))
        .min(f64::from(work.height) * MARGIN / f64::from(height.max(1)))
        .min(1.0);
    let width = ((f64::from(width) * fit) as u32).max(min_width.min(work.width));
    let height = ((f64::from(height) * fit) as u32).max(min_height.min(work.height));
    Rect {
        x: work.x + (work.width.saturating_sub(width) / 2) as i32,
        y: work.y + (work.height.saturating_sub(height) / 2) as i32,
        width,
        height,
    }
}

pub fn center_on_active_screen(app: &tauri::AppHandle) {
    use tauri::Manager;
    let Some(window) = app.get_webview_window("main") else { return };
    let monitor = app.cursor_position().ok()
        .and_then(|point| app.monitor_from_point(point.x, point.y).ok().flatten())
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let area = monitor.work_area();
    let scale = monitor.scale_factor();
    // The configured size (1280×820) and minimum (820×590) are logical pixels.
    let physical = |value: f64| (value * scale).round() as u32;
    let work = Rect { x: area.position.x, y: area.position.y, width: area.size.width, height: area.size.height };
    let place = centered(work, physical(1280.0), physical(820.0), physical(820.0), physical(590.0));
    let _ = window.set_size(tauri::PhysicalSize::new(place.width, place.height));
    let _ = window.set_position(tauri::PhysicalPosition::new(place.x, place.y));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_window_is_centered_on_the_usable_area_and_shrinks_only_when_it_must() {
        let full_hd = Rect { x: 0, y: 0, width: 1920, height: 1032 };
        assert_eq!(centered(full_hd, 1280, 820, 820, 590), Rect { x: 320, y: 106, width: 1280, height: 820 });
        // A second screen to the left, at 125 %: the size in physical pixels, centered on that screen.
        let left = Rect { x: -1920, y: 0, width: 1920, height: 1152 };
        let placed = centered(left, 1600, 1025, 1025, 738);
        assert_eq!((placed.width, placed.height), (1600, 1025));
        assert_eq!(placed.x, -1920 + 160);
        // A small laptop screen: smaller, same proportion, never under the minimum, still centered.
        let small = Rect { x: 0, y: 0, width: 1366, height: 728 };
        let placed = centered(small, 1280, 820, 820, 590);
        assert!(placed.height <= 728 && placed.width <= 1366 && placed.height >= 590, "{placed:?}");
        assert_eq!(placed.y, ((728 - placed.height) / 2) as i32);
        assert!((f64::from(placed.width) / f64::from(placed.height) - 1280.0 / 820.0).abs() < 0.01);
    }
}
