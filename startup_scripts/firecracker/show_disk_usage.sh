# Both sizes side-by-side
echo "APPARENT SIZE vs ACTUAL DISK USAGE"
echo "===================================="
for f in overlays/*.ext4; do
    apparent=$(ls -lh "$f" | awk '{print $5}')
    actual=$(du -h "$f" | cut -f1)
    name=$(basename "$f")
    printf "%-30s  %6s  %6s\n" "$name" "$apparent" "$actual"
done
