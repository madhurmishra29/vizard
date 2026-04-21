import { Resend } from 'resend';

const resend = new Resend(process.env.RESEND_API_KEY);

export async function sendMagicLink(email: string, link: string) {
  await resend.emails.send({
    from: 'noreply@vizardau.com',
    to: email,
    subject: 'Your sign-in link for Vizard',
    html: `
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
</head>
<body style="margin:0;padding:0;background:#f9f9f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="padding:40px 0;">
    <tr>
      <td align="center">
        <table width="480" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:8px;padding:40px;border:1px solid #e8e8e8;">
          <tr>
            <td style="font-size:22px;font-weight:600;color:#111;">Sign in to Vizard</td>
          </tr>
          <tr>
            <td style="padding-top:16px;font-size:15px;color:#555;line-height:1.6;">
              Click the button below to sign in. This link expires in 10 minutes and can only be used once.
            </td>
          </tr>
          <tr>
            <td style="padding-top:32px;">
              <a href="${link}" style="display:inline-block;background:#111;color:#fff;font-size:15px;font-weight:500;text-decoration:none;padding:12px 28px;border-radius:6px;">
                Sign in
              </a>
            </td>
          </tr>
          <tr>
            <td style="padding-top:32px;font-size:13px;color:#999;line-height:1.6;">
              If you didn't request this, you can safely ignore this email.<br />
              This link was sent to ${email}.
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
    `.trim(),
  });
}
