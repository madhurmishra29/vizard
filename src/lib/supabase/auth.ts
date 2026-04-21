import { createClient } from './server';

export async function sendMagicLinkAuth(email: string) {
  const supabase = await createClient();

  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: {
      shouldCreateUser: true,
    },
  });

  if (error) throw error;
}

export async function getSession() {
  const supabase = await createClient();

  const { data: { session }, error } = await supabase.auth.getSession();

  if (error) throw error;

  return session;
}
