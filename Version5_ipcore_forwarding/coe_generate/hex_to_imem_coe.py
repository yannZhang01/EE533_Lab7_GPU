import argparse
import re

def read_hex_words(path: str):
    words = []
    with open(path, "r") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue

            # Strip simple comments
            line = re.split(r"//|#", line, maxsplit=1)[0].strip()
            if not line:
                continue

            # Optional 0x prefix
            if line.lower().startswith("0x"):
                line = line[2:]

            # Optional address directive like "@0010" (ignored in linear mode)
            if line.startswith("@"):
                continue

            if not re.fullmatch(r"[0-9A-Fa-f]{1,8}", line):
                raise ValueError(f"Invalid hex word line: {raw!r}")

            words.append(int(line, 16))
    return words

def write_coe(words, out_path: str, radix: int, width_bits: int, depth: int | None):
    hex_digits = (width_bits + 3) // 4
    if depth is None:
        depth = len(words)

    padded = list(words[:depth]) + [0] * max(0, depth - len(words))

    vec = ",\n".join(f"{v:0{hex_digits}X}" for v in padded) + ";"
    content = (
        f"memory_initialization_radix={radix};\n"
        f"memory_initialization_vector=\n"
        f"{vec}\n"
    )
    with open(out_path, "w") as f:
        f.write(content)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hex", required=True, help="Input hex file, 1 word per line (8 hex digits for 32-bit).")
    ap.add_argument("--out", required=True, help="Output .coe file.")
    ap.add_argument("--width", type=int, default=32, help="Word width in bits (default: 32).")
    ap.add_argument("--depth", type=int, default=None, help="Memory depth (default: number of words in hex).")
    ap.add_argument("--radix", type=int, default=16, help="COE radix (default: 16).")
    args = ap.parse_args()

    words = read_hex_words(args.hex)
    write_coe(words, args.out, args.radix, args.width, args.depth)

if __name__ == "__main__":
    main()