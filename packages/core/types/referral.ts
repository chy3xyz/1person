export type ReferralStatus = "registered" | "activated" | "paid";

export interface ReferralCode {
  code: string;
  userId: string;
  workspaceId: string;
}

export interface ReferralRecord {
  id: string;
  code: string;
  referrerUserId: string;
  refereeUserId: string;
  status: ReferralStatus;
  rewardedAt: string;
}
