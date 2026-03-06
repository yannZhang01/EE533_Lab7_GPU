import argparse

def write_coe(words, out_path: str, width_bits: int, depth: int, radix: int = 16):
    hex_digits = (width_bits + 3) // 4
    padded = list(words[:depth]) + [0] * max(0, depth - len(words))

    vec = ",\n".join(f"{v:0{hex_digits}X}" for v in padded) + ";"
    content = (
        f"memory_initialization_radix={radix};\n"
        f"memory_initialization_vector=\n"
        f"{vec}\n"
    )

    with open(out_path, "w") as f:
        f.write(content)

def write_hex(words, out_path: str, width_bits: int, depth: int):
    hex_digits = (width_bits + 3) // 4
    padded = list(words[:depth]) + [0] * max(0, depth - len(words))
    content = "\n".join(f"{v:0{hex_digits}X}" for v in padded) + "\n"

    with open(out_path, "w") as f:
        f.write(content)

def parse_hex_64(s: str) -> int:
    t = s.strip().rstrip(",").replace("_", "")
    if t.lower().startswith("0x"):
        t = t[2:]
    if len(t) == 0:
        raise ValueError("Empty hex token.")
    v = int(t, 16)
    return v & ((1 << 64) - 1)

def main():
    ap = argparse.ArgumentParser(description="Generate COE + HEX for 64-bit x 256 DMEM init (fixed first 10 entries).")
    ap.add_argument("--out_coe", required=True, help="Output .coe file path (for IP init).")
    ap.add_argument("--out_hex", required=True, help="Output .hex file path (for $readmemh in TB).")
    ap.add_argument("--radix", type=int, default=16, help="COE radix (default: 16).")
    args = ap.parse_args()

    width_bits = 64
    depth = 256

    fixed10_str = [
        "0000000000000007",
        "0000000000000028",
        "0000000000000001",
        "0000000000000005",
        "FFFFFFFFFFFFFFD8",
        "0000000000000014",
        "00000000000002E2",
        "0000000000000000",
        "FFFFFFFFFFFFFFF9",
        "0000000000000006",
    ]

    words = [parse_hex_64(x) for x in fixed10_str]

    write_coe(words, args.out_coe, width_bits=width_bits, depth=depth, radix=args.radix)
    write_hex(words, args.out_hex, width_bits=width_bits, depth=depth)

if __name__ == "__main__":
    main()