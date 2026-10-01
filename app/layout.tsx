import type { ReactNode } from "react";

export const metadata = {
  title: "Draw Me Processor",
  description: "Image-to-drawing preprocessing service for a Roblox experiment.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          fontFamily: "system-ui, sans-serif",
          background: "#0c0d11",
          color: "#f5f7ff",
        }}
      >
        {children}
      </body>
    </html>
  );
}
