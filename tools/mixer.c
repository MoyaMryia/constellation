/*
 * mixer — 极小的 OSS 混音器客户端，给没有 alsa-utils 的 Constellation
 * 目标机用。
 *
 * 为什么用 OSS 接口而不是 ALSA：ALSA 的 libasound 是几 MB 的依赖，而这个
 * 镜像的全部用户空间就是 BusyBox + s6。内核打开 CONFIG_SND_MIXER_OSS 后，
 * /dev/mixer 由 snd-mixer-oss 模块提供，用三个 ioctl 就能读写主音量。
 *
 * 用法：
 *   mixer              打印当前主音量（左 右，0..100）
 *   mixer 80           左右都设 80
 *   mixer 80 60        左 80 右 60
 *   mixer mute / on    静音 / 取消静音
 *
 * 退出码：0 成功；1 打不开或 ioctl 失败（例如声卡驱动没绑上）。
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/*
 * 不 include <linux/soundcard.h>：musl 的 <sys/soundcard.h> 是空的占位，
 * uapi 头在 headers_install 里也不保证存在。这三个定义就是 OSS 混音器
 * 用到的全部 ABI（与 linux/soundcard.h 在 _IOWR 可用时的展开完全一致）。
 */
#define SOUND_MIXER_VOLUME 0
#define MIXER_READ(dev)    _IOR('M', dev, int)
#define MIXER_WRITE(dev)   _IOWR('M', dev, int)

static int open_mixer(void)
{
	int fd = open("/dev/mixer", O_RDWR);
	if (fd < 0)
		fd = open("/dev/mixer", O_RDONLY);
	if (fd < 0) {
		perror("mixer: /dev/mixer");
		fprintf(stderr, "mixer: 声卡驱动未绑定，或内核缺 CONFIG_SND_MIXER_OSS\n");
	}
	return fd;
}

static int read_volume(int fd, int *left, int *right)
{
	int vol = 0;
	if (ioctl(fd, MIXER_READ(SOUND_MIXER_VOLUME), &vol) < 0) {
		perror("mixer: MIXER_READ");
		return -1;
	}
	*left = vol & 0xff;
	*right = (vol >> 8) & 0xff;
	return 0;
}

static int write_volume(int fd, int left, int right)
{
	int vol;
	if (left < 0) left = 0;
	if (left > 100) left = 100;
	if (right < 0) right = 0;
	if (right > 100) right = 100;
	vol = (left & 0xff) | ((right & 0xff) << 8);
	if (ioctl(fd, MIXER_WRITE(SOUND_MIXER_VOLUME), &vol) < 0) {
		perror("mixer: MIXER_WRITE");
		return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	int fd, left, right;

	if (argc > 1 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
		fprintf(stderr, "用法: mixer [左 [右]] | mixer mute | mixer on\n");
		return 0;
	}

	fd = open_mixer();
	if (fd < 0)
		return 1;

	if (argc == 1) {
		if (read_volume(fd, &left, &right) < 0)
			return 1;
		printf("%d %d\n", left, right);
		return 0;
	}

	if (strcmp(argv[1], "mute") == 0) {
		if (write_volume(fd, 0, 0) < 0)
			return 1;
		printf("muted\n");
		return 0;
	}
	if (strcmp(argv[1], "on") == 0) {
		if (write_volume(fd, 80, 80) < 0)
			return 1;
		printf("80 80\n");
		return 0;
	}

	left = atoi(argv[1]);
	right = (argc > 2) ? atoi(argv[2]) : left;
	if (write_volume(fd, left, right) < 0)
		return 1;
	if (read_volume(fd, &left, &right) < 0)
		return 1;
	printf("%d %d\n", left, right);
	return 0;
}
