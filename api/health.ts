export default {
  fetch() {
    return Response.json({
      ok: true,
      service: "draw-me-image-processor",
      version: 1,
    });
  },
};
