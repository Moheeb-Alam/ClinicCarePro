import type { Metadata } from "next";
import { Geist } from "next/font/google";
import AppFrame from "./app-frame";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "ClinicCare Pro | Clinic Operations",
  description: "Connected clinic, laboratory, and diagnostic center operations.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={`${geistSans.variable} h-full antialiased`}>
      <body className="min-h-full"><AppFrame>{children}</AppFrame></body>
    </html>
  );
}
