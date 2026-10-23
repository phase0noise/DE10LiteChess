"""Independently check the depth-six boundary and forced insufficient draws."""
from pathlib import Path
import chess
from generate_fixtures import encode_move, position_bytes


def main():
    lines = []
    for mirrored in (False, True):
        board = chess.Board('8/8/8/8/8/8/r1k5/K7 w - - 0 1')
        if mirrored:
            board = board.mirror()
        assert board.is_valid()
        legal = list(board.legal_moves)
        assert len(legal) == 1
        move = legal[0]
        after = board.copy()
        after.push(move)
        assert after.is_insufficient_material()
        maps = []
        for color in (chess.WHITE, chess.BLACK):
            attack = 0
            for square, piece in board.piece_map().items():
                if piece.color == color:
                    attack |= int(board.attacks(square))
            maps.extend(attack.to_bytes(8, 'little'))
        code = encode_move(move)
        lines.append(' '.join(map(str, [*position_bytes(board), 1, code, *maps,
            -1, -1, 0, code, *position_bytes(after)])))
    output = Path(__file__).resolve().parents[1] / '.cache/depth_vectors.txt'
    output.write_text('\n'.join(lines) + '\n', encoding='ascii')
    print('Proved two forced king captures leading to insufficient-material draws.')


if __name__ == '__main__':
    main()
