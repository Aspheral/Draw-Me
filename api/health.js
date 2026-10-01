module.exports = function handler(_req, res) {
  res.status(200).json({
    ok: true,
    service: "draw-me-image-processor",
    version: 1,
  });
};
