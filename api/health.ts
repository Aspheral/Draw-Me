export default function handler(_req: any, res: any) {
  res.status(200).json({
    ok: true,
    service: "draw-me-image-processor",
    version: 1,
  });
}
