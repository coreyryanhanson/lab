# ffmpeg

## Creating Gifs
```bash
# Simple command to build a looping gif with an optimized custom palette but have it output at 12 fps.
ffmpeg -i input.mov -framerate 12 -vf "fps=12,scale=720:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" -loop 0 output.gif
```

## Joining clips:
```bash
# Basic concatenate.
ffmpeg -i "concat:input_1.MTS|input_2.MTS|input_3.MTS" -c copy output.MTS
```

```bash
# If unsupported audio codec.
ffmpeg -i "concat:input_1.MTS|input_2.MTS|input_3.MTS" -vcodec copy -acodec ac3 output.MTS
```
## Common formats:

### Prores
```bash
### Profile 3 is Prores 422 HQ, 2 is regular, 4 is 4444 10 bit, 1 is proxy
ffmpeg -i input.mp4 -c:a pcm_s24le -c:v prores -pixel_format yuv422p10lep -profile:v 3 output.mov

ffmpeg -i input.mp4 -c:a pcm_s24le -c:v prores -pixel_format yuva444p10le -profile:v 4 output.mov
```
