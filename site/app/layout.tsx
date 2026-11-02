import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import type { ReactNode } from "react";
import "./globals.css";

const geist = Geist({ subsets: ["latin"], variable: "--font-geist", weight: ["400", "500", "600"] });
const geistMono = Geist_Mono({ subsets: ["latin"], variable: "--font-geist-mono", weight: ["400", "500"] });

export const metadata: Metadata = {
  metadataBase: new URL("https://keybinds.app"),
  title: "Keybinds — everything on your Mac, a keystroke away",
  description:
    "Keybinds is a command palette for your whole Mac. Jump to any app, window, tab or file, and click any button on screen, from the keyboard.",
  icons: { icon: "/assets/favicon-32.png", apple: "/assets/icon-512.png" },
  openGraph: {
    title: "Keybinds",
    description: "Every tab, every window. A keystroke away.",
    images: "/assets/icon-512.png",
  },
};

// Your choice if you made one, otherwise the system's; set before first paint.
const theme = `document.documentElement.dataset.theme = localStorage.getItem("theme")
  || (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");`;

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${geist.variable} ${geistMono.variable}`} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: theme }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
