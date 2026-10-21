//! HelloCargo: one window cleared to one colour. A plain Cargo app for iOS and macOS, packaged by xless with the
//! overlay in `xless.overlay.example.yml` (no Xcode project).
use std::num::NonZeroU32;
use std::rc::Rc;

use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::window::{Window, WindowId};

/// 0x00RRGGBB.
const COLOR: u32 = 0x0024_70A0;

struct Surface {
    window: Rc<Window>,
    surface: softbuffer::Surface<Rc<Window>, Rc<Window>>,
}

#[derive(Default)]
struct App {
    surface: Option<Surface>,
}

impl App {
    fn open(event_loop: &ActiveEventLoop) -> Result<Surface, Box<dyn std::error::Error>> {
        let window = Rc::new(event_loop.create_window(Window::default_attributes().with_title("HelloCargo"))?);
        let context = softbuffer::Context::new(window.clone())?;
        let surface = softbuffer::Surface::new(&context, window.clone())?;
        Ok(Surface { window, surface })
    }
}

impl Surface {
    fn draw(&mut self) -> Result<(), softbuffer::SoftBufferError> {
        let size = self.window.inner_size();
        let (Some(width), Some(height)) = (NonZeroU32::new(size.width), NonZeroU32::new(size.height)) else {
            return Ok(()); // minimised: nothing to draw
        };
        self.surface.resize(width, height)?;
        let mut buffer = self.surface.buffer_mut()?;
        buffer.fill(COLOR);
        buffer.present()
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.surface.is_some() {
            return;
        }
        match App::open(event_loop) {
            Ok(surface) => {
                surface.window.request_redraw();
                self.surface = Some(surface);
            }
            Err(error) => {
                eprintln!("HelloCargo: cannot open a window: {error}");
                event_loop.exit();
            }
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::RedrawRequested => {
                if let Some(Err(error)) = self.surface.as_mut().map(Surface::draw) {
                    eprintln!("HelloCargo: cannot draw: {error}");
                }
            }
            WindowEvent::Resized(_) => {
                if let Some(surface) = &self.surface {
                    surface.window.request_redraw();
                }
            }
            _ => {}
        }
    }
}

fn main() {
    let event_loop = match EventLoop::new() {
        Ok(event_loop) => event_loop,
        Err(error) => {
            eprintln!("HelloCargo: cannot start the event loop: {error}");
            std::process::exit(1);
        }
    };
    if let Err(error) = event_loop.run_app(&mut App::default()) {
        eprintln!("HelloCargo: {error}");
        std::process::exit(1);
    }
}
