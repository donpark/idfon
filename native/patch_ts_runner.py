from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
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
path.write_text(source)
