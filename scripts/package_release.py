"""Package the five GUI builds produced by zig build release-all."""
import hashlib,shutil,sys
from pathlib import Path
VERSION="0.1.18"
source=Path(sys.argv[1]) if len(sys.argv)>1 else Path("zig-out/bin")
out=Path(sys.argv[2]) if len(sys.argv)>2 else Path("release")
out.mkdir(parents=True,exist_ok=True)
targets={"x86_64-windows":"windows-x86_64.exe","x86_64-linux-musl":"linux-x86_64","aarch64-linux-musl":"linux-arm64","x86_64-macos":"macos-x86_64","aarch64-macos":"macos-arm64"}
sums=[]
for target,suffix in targets.items():
 src=source/target/("freepro.exe" if target.endswith("windows") else "freepro")
 dst=out/f"freepro-v{VERSION}-{suffix}"
 shutil.copyfile(src,dst)
 if not suffix.endswith(".exe"):dst.chmod(0o755)
 sums.append(f"{hashlib.sha256(dst.read_bytes()).hexdigest()}  {dst.name}")
 print(f"{dst.name}: {dst.stat().st_size:,} bytes")
(out/"SHA256SUMS").write_text("\n".join(sums)+"\n",encoding="utf-8")
