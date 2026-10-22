"""Check that the distributable contains all of its build/runtime inputs."""
from pathlib import Path
import re
import sys

def check(root):
    root = root.resolve()
    qsf = root / 'de10_chess.qsf'
    count = 0
    for kind, value in re.findall(r'^set_global_assignment -name (VHDL_FILE|VERILOG_FILE|SDC_FILE|QIP_FILE)\s+(.+)$', qsf.read_text(), re.M):
        name = value.strip().strip('"')
        path = (root / name).resolve()
        if Path(name).is_absolute() or not path.is_relative_to(root) or not path.is_file():
            raise ValueError(f'Build input is missing or outside the project: {kind} {name}')
        count += 1
    required = ['de10_chess.qpf','firmware/pico_chess/pico_chess.ino',
                'firmware/pico_chess/chess_protocol.h','firmware/pico_chess/web_page.h',
                'web/index.html','web/style.css','web/chess.js','web/fpga.js','web/app.js','web/pieces.png']
    for name in required:
        if not (root / name).is_file():
            raise ValueError(f'Missing project input: {name}')
    embedded = (root / 'firmware/pico_chess/web_page.h').read_text(encoding='utf8')
    if re.search(r'<(?:script|link)\b[^>]+(?:src|href)=', embedded):
        raise ValueError('Embedded page still loads external scripts/styles')
    if 'data:image/png;base64,' not in embedded:
        raise ValueError('Embedded chess artwork is missing')
    print(f'PASS: {count} FPGA inputs and all firmware/web assets are inside {root.name}.')

if __name__ == '__main__':
    check(Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[1])
