export interface FcmMessage {
  token: string;
  notification: { title: string; body: string };
  data: Record<string, string>;
  android: { priority: 'high'; notification: { channel_id: string } };
}

export interface Fcm {
  send(message: FcmMessage): Promise<'sent' | 'invalid' | 'failed'>;
}

export function makeFcm(projectId: string, accessToken: string): Fcm {
  return {
    async send(message) {
      const response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/messages:send`,
        {
          method: 'POST',
          headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ message }),
        },
      );
      if (response.ok) return 'sent';
      const body = await response.text();
      if (response.status === 404 || /UNREGISTERED|INVALID_ARGUMENT/.test(body)) return 'invalid';
      return 'failed';
    },
  };
}
