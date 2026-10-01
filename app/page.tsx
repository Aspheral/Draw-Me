export default function Home() {
  return (
    <main style={{ maxWidth: 760, margin: "64px auto", padding: 24 }}>
      <h1 style={{ fontSize: 40, marginBottom: 8 }}>Draw Me Processor</h1>
      <p style={{ color: "#b8bfd3", lineHeight: 1.6 }}>
        The server is online. POST an image URL to <code>/api/prepare</code> to
        convert it into compact drawing segments.
      </p>
      <pre
        style={{
          background: "#171923",
          borderRadius: 12,
          padding: 18,
          overflowX: "auto",
          lineHeight: 1.5,
        }}
      >
        {'POST /api/prepare\nContent-Type: application/json\n\n{\n  "url": "https://example.com/image.png",\n  "width": 64,\n  "height": 64,\n  "colors": 16,\n  "skipWhite": true\n}'}
      </pre>
    </main>
  );
}
