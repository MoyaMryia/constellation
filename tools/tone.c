/* tone -- 最简单的扬声器自检：在 OSS /dev/dsp 上放一段正弦音。
 *
 * 为什么需要它：mpg123 要 MP3 文件、aplay 要 ALSA，而第一次验证这台机器的
 * CS4237B 是否能出声，只需要一个 3 秒的 440 Hz 音。
 *
 *   tone                440 Hz, 3 秒, 16-bit 单声道, 44100 Hz
 *   tone 880 2          880 Hz, 2 秒
 *   tone 440 3 22050    指定采样率
 *   tone sweep          220 -> 880 Hz 滑音，听起来更容易判断"确实在响"
 *
 * 编译：tcc tone.c -o tone      （或用交叉工具链，静态）
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/soundcard.h>
#include <math.h>

int main(int argc, char **argv)
{
    double freq = 440.0, dur = 3.0, sweep = 0.0;
    int rate = 44100, fd, fmt, ch, i;
    int frames, ramp;
    short buf[4096];

    if (argc > 1 && strcmp(argv[1], "sweep") == 0) {
        sweep = 660.0;                  /* 220 -> 880 */
        freq = 220.0;
        if (argc > 2) dur = atof(argv[2]);
    } else {
        if (argc > 1) freq = atof(argv[1]);
        if (argc > 2) dur = atof(argv[2]);
    }
    if (argc > 3) rate = atoi(argv[3]);
    if (freq <= 0 || dur <= 0 || rate < 4000) {
        fprintf(stderr, "usage: tone [freq|sweep] [seconds] [rate]\n");
        return 2;
    }

    fd = open("/dev/dsp", O_WRONLY);
    if (fd < 0) {
        perror("tone: open /dev/dsp");
        fprintf(stderr, "  hint: lsmod | grep snd; modprobe snd-pcm-oss\n");
        return 1;
    }
    fmt = AFMT_S16_LE;  ioctl(fd, SNDCTL_DSP_SETFMT, &fmt);
    ch  = 1;            ioctl(fd, SNDCTL_DSP_CHANNELS, &ch);
    ioctl(fd, SNDCTL_DSP_SPEED, &rate);
    printf("tone: %s %.0f Hz, %.1f s, %d Hz, %d-bit %s\n",
           sweep > 0 ? "sweep" : "sine", freq, dur, rate,
           fmt == AFMT_S16_LE ? 16 : 8, ch == 1 ? "mono" : "stereo");

    frames = (int)(dur * rate);
    ramp = rate / 50;                   /* 20 ms 淡入淡出，避免爆音 */
    {
        double phase = 0.0, f = freq;
        int done = 0, n;
        while (done < frames) {
            n = frames - done;
            if (n > (int)(sizeof(buf) / sizeof(buf[0]))) n = sizeof(buf) / sizeof(buf[0]);
            for (i = 0; i < n; i++) {
                double amp = 12000.0;
                if (done + i < ramp) amp *= (double)(done + i) / ramp;
                if (frames - (done + i) < ramp) amp *= (double)(frames - done - i) / ramp;
                buf[i] = (short)(amp * sin(phase));
                phase += 2.0 * M_PI * f / rate;
                if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;
                if (sweep > 0) f = freq + (sweep - freq) * (double)(done + i) / frames;
            }
            if (write(fd, buf, n * sizeof(short)) < 0) { perror("tone: write"); break; }
            done += n;
        }
    }
    ioctl(fd, SNDCTL_DSP_SYNC, 0);
    close(fd);
    return 0;
}
