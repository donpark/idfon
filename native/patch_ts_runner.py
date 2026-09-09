from pathlib import Path
import re
import sys

# The app's vector icons (assets/icons/*.svg), parsed at comptime by the
# generated runner and registered so markup can draw them as `app:<name>`.
# Read from disk here because the runner is generated into .zig-cache and
# cannot @embedFile app files; build.zig re-runs this patch when any icon
# file changes. Names must be lowercase-dashed (e.g. app:wave).
APP_ICONS = {
    svg.stem: svg.read_text().strip()
    for svg in sorted((Path(__file__).parent / "assets" / "icons").glob("*.svg"))
}
if not APP_ICONS:
    raise SystemExit('no icons found in assets/icons/')

path = Path(sys.argv[1])
source = path.read_text()

# Strip any previously injected app-icon block so the injection below can
# upgrade it (the runner file itself is content-cached across builds).
source = re.sub(
    r'const app_icon_\w+ = native_sdk\.canvas\.svg_icon\.parseComptime\(.*?\n    \);\n',
    '', source, flags=re.S,
)
source = re.sub(r'const app_icon_table = .*?\n', '', source, flags=re.S)
source = re.sub(r'pub const app_icons = .*?\n', '', source)
source = source.replace('    native_sdk.canvas.icons.registerAppIcons(&app_icon_table);\n', '')
source = source.replace('    native_sdk.canvas.icons.registerAppIcons(&app_icons);\n', '')
if 'const iroh_host = @import("iroh_host");' not in source:
    source = source.replace('const window_views = @import("window_views.zig");\n', 'const window_views = @import("window_views.zig");\nconst iroh_host = @import("iroh_host");\n', 1)
old = '''        .host_calls = if (comptime use_pool)
            pool_transport.binding()
        else if (comptime use_child)
            child_transport.binding()
        else
            null,'''
new = '''        .host_calls = if (comptime use_pool)
            pool_transport.binding()
        else if (comptime use_child)
            child_transport.binding()
        else
            iroh_host.binding(),'''
if old in source:
    source = source.replace(old, new, 1)
elif 'iroh_host.binding(),' not in source:
    raise SystemExit('generated runner host binding block changed')

# Register app icons: `pub const app_icons` on the app root feeds the model
# contract (native check verifies `app:<name>` references); the boot-time
# registerAppIcons call feeds the draw paths. Built-ins win on collision.
if 'pub const app_icons' not in source:
    table_lines = '\n'.join(
        f'const app_icon_{name} = native_sdk.canvas.svg_icon.parseComptime(\n'
        f'        \\\\{svg}\n'
        f'    );' for name, svg in APP_ICONS.items()
    )
    entries = ', '.join(f'.{{ .name = "{name}", .icon = &app_icon_{name} }}' for name in APP_ICONS)
    decls = (table_lines
        + f'\nconst app_icon_table = [_]native_sdk.canvas.icons.Entry{{ {entries} }};'
        + '\npub const app_icons = &app_icon_table;\n')
    source = source.replace(
        'pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);',
        decls + '\npub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);',
        1,
    )
    source = source.replace(
        'pub fn main(init: std.process.Init) !void {\n',
        'pub fn main(init: std.process.Init) !void {\n    native_sdk.canvas.icons.registerAppIcons(&app_icon_table);\n',
        1,
    )
path.write_text(source)
