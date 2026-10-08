// Does a GL texture rendered in one process arrive, zero-copy, as a texture in
// another? That is the whole of phase 2 of the Linux port, asked without an
// engine or a GUI in the way.
//
// Parent — the guest: render red into a texture, `eglExportDMABUFImageMESA` it,
// send the fd over a socketpair with SCM_RIGHTS. Child — standing in for the
// studio: a *fresh* EGLDisplay, import the fd with EGL_LINUX_DMA_BUF_EXT, bind
// it with glEGLImageTargetTexture2DOES and read the centre pixel back. Exit 0
// means it came through.
//
//   cc dmabuf_probe.c -lEGL -lGLESv2 -o dmabuf_probe && ./dmabuf_probe
//
// Two things it does not prove: the importing display here is ours rather than
// Flutter's, and the export half is a Mesa extension that NVIDIA's proprietary
// EGL does not have — which is why the shared-memory path has to exist
// whatever this says.
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <drm/drm_fourcc.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#define W 256
#define H 128

static EGLDisplay open_display(void) {
  PFNEGLGETPLATFORMDISPLAYEXTPROC get =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
          "eglGetPlatformDisplayEXT");
  EGLDisplay d = get(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
  EGLint mj, mn;
  if (!eglInitialize(d, &mj, &mn)) return EGL_NO_DISPLAY;
  eglBindAPI(EGL_OPENGL_ES_API);
  return d;
}

static EGLContext make_context(EGLDisplay d) {
  EGLint ca[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE,
                 EGL_OPENGL_ES3_BIT, EGL_NONE};
  EGLConfig cfg;
  EGLint n;
  eglChooseConfig(d, ca, &cfg, 1, &n);
  EGLint xa[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  EGLContext c = eglCreateContext(d, cfg, EGL_NO_CONTEXT, xa);
  eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, c);
  return c;
}

static bool send_fd(int sock, int fd, const uint8_t* meta, size_t meta_len) {
  struct iovec iov = {.iov_base = (void*)meta, .iov_len = meta_len};
  char cbuf[CMSG_SPACE(sizeof(int))];
  struct msghdr msg = {0};
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = cbuf;
  msg.msg_controllen = sizeof(cbuf);
  struct cmsghdr* c = CMSG_FIRSTHDR(&msg);
  c->cmsg_level = SOL_SOCKET;
  c->cmsg_type = SCM_RIGHTS;
  c->cmsg_len = CMSG_LEN(sizeof(int));
  memcpy(CMSG_DATA(c), &fd, sizeof(int));
  return sendmsg(sock, &msg, 0) > 0;
}

static int recv_fd(int sock, uint8_t* meta, size_t meta_len) {
  struct iovec iov = {.iov_base = meta, .iov_len = meta_len};
  char cbuf[CMSG_SPACE(sizeof(int))];
  struct msghdr msg = {0};
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = cbuf;
  msg.msg_controllen = sizeof(cbuf);
  if (recvmsg(sock, &msg, 0) <= 0) return -1;
  struct cmsghdr* c = CMSG_FIRSTHDR(&msg);
  if (!c || c->cmsg_type != SCM_RIGHTS) return -1;
  int fd;
  memcpy(&fd, CMSG_DATA(c), sizeof(int));
  return fd;
}

int main(void) {
  int sv[2];
  socketpair(AF_UNIX, SOCK_STREAM, 0, sv);

  pid_t pid = fork();
  if (pid == 0) {
    // ---- child: the "GUI" ----
    close(sv[0]);
    EGLDisplay d = open_display();
    make_context(d);
    // meta: fourcc, stride, offset, modifier_lo, modifier_hi
    uint32_t meta[3];
    uint64_t mod;
    uint8_t buf[sizeof(meta) + sizeof(mod)];
    int fd = recv_fd(sv[1], buf, sizeof(buf));
    if (fd < 0) { fprintf(stderr, "child: no fd\n"); return 1; }
    memcpy(meta, buf, sizeof(meta));
    memcpy(&mod, buf + sizeof(meta), sizeof(mod));
    fprintf(stderr, "child: fd=%d fourcc=%.4s stride=%u offset=%u mod=%llx\n",
            fd, (char*)&meta[0], meta[1], meta[2],
            (unsigned long long)mod);

    EGLAttrib attrs[] = {
        EGL_WIDTH, W,
        EGL_HEIGHT, H,
        EGL_LINUX_DRM_FOURCC_EXT, (EGLAttrib)meta[0],
        EGL_DMA_BUF_PLANE0_FD_EXT, fd,
        EGL_DMA_BUF_PLANE0_OFFSET_EXT, (EGLAttrib)meta[2],
        EGL_DMA_BUF_PLANE0_PITCH_EXT, (EGLAttrib)meta[1],
        EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, (EGLAttrib)(mod & 0xffffffff),
        EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, (EGLAttrib)(mod >> 32),
        EGL_NONE};
    PFNEGLCREATEIMAGEPROC create =
        (PFNEGLCREATEIMAGEPROC)eglGetProcAddress("eglCreateImage");
    EGLImage img = create(d, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
    if (img == EGL_NO_IMAGE) {
      fprintf(stderr, "child: IMPORT FAILED 0x%x\n", eglGetError());
      return 1;
    }
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC bind =
        (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress(
            "glEGLImageTargetTexture2DOES");
    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    bind(GL_TEXTURE_2D, img);
    GLuint fbo;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           tex, 0);
    uint8_t px[4];
    glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    fprintf(stderr, "child: centre pixel = %u,%u,%u,%u\n", px[0], px[1], px[2],
            px[3]);
    return (px[0] > 200 && px[1] < 60 && px[2] < 60) ? 0 : 2;
  }

  // ---- parent: the "guest" ----
  close(sv[1]);
  EGLDisplay d = open_display();
  EGLContext c = make_context(d);
  GLuint tex, fbo;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE,
               NULL);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         tex, 0);
  glClearColor(1, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glFinish();

  PFNEGLCREATEIMAGEPROC create =
      (PFNEGLCREATEIMAGEPROC)eglGetProcAddress("eglCreateImage");
  EGLImage img = create(d, c, EGL_GL_TEXTURE_2D,
                        (EGLClientBuffer)(uintptr_t)tex, NULL);
  if (img == EGL_NO_IMAGE) {
    fprintf(stderr, "parent: image from texture failed 0x%x\n", eglGetError());
    return 1;
  }
  PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC query =
      (PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC)eglGetProcAddress(
          "eglExportDMABUFImageQueryMESA");
  PFNEGLEXPORTDMABUFIMAGEMESAPROC export =
      (PFNEGLEXPORTDMABUFIMAGEMESAPROC)eglGetProcAddress(
          "eglExportDMABUFImageMESA");
  if (!query || !export) { fprintf(stderr, "parent: no MESA export\n"); return 1; }
  int fourcc, nplanes;
  EGLuint64KHR modifiers;
  if (!query(d, img, &fourcc, &nplanes, &modifiers)) {
    fprintf(stderr, "parent: query failed 0x%x\n", eglGetError());
    return 1;
  }
  int fd = -1;
  EGLint stride = 0, offset = 0;
  if (!export(d, img, &fd, &stride, &offset)) {
    fprintf(stderr, "parent: export failed 0x%x\n", eglGetError());
    return 1;
  }
  fprintf(stderr, "parent: planes=%d fourcc=%.4s stride=%d offset=%d mod=%llx\n",
          nplanes, (char*)&fourcc, stride, offset,
          (unsigned long long)modifiers);
  uint8_t buf[3 * 4 + 8];
  uint32_t meta[3] = {(uint32_t)fourcc, (uint32_t)stride, (uint32_t)offset};
  uint64_t mod = modifiers;
  memcpy(buf, meta, sizeof(meta));
  memcpy(buf + sizeof(meta), &mod, sizeof(mod));
  send_fd(sv[0], fd, buf, sizeof(buf));

  int status = 0;
  waitpid(pid, &status, 0);
  int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
  fprintf(stderr, "child exit=%d %s\n", code,
          code == 0 ? "ZERO-COPY OK" : "FAILED");
  return code;
}
