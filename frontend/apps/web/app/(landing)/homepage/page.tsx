import type { Metadata } from "next";
import { LandingPage as HomePage } from "@/features/landing/components/landing-page";

export const metadata: Metadata = {
  title: "Homepage",
  description:
    "1Person — open-source platform that turns coding agents into real teammates. Assign tasks, track progress, compound skills.",
  openGraph: {
    title: "1Person — Project Management for Human + Agent Teams",
    description:
      "Manage your human + agent workforce in one place.",
    url: "/homepage",
  },
  alternates: {
    canonical: "/homepage",
  },
};

export default function HomepagePage() {
  return <HomePage />;
}
