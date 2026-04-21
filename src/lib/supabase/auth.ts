import { createClient } from './server';

export type UserTier = 'free' | 'authenticated';

export async function sendMagicLinkAuth(email: string) {
  const supabase = await createClient();

  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: {
      shouldCreateUser: true,
    },
  });

  if (error) throw error;

  // Ensure a subscription row exists with a default tier of 'free'.
  // The new_user_setup DB trigger creates this on sign-up, but for
  // existing users who pre-date the trigger we upsert defensively.
  const { data: { user } } = await supabase.auth.getUser();
  if (user) {
    await supabase
      .from('subscriptions')
      .upsert({ user_id: user.id, plan: 'free' }, { onConflict: 'user_id', ignoreDuplicates: true });
  }
}

export async function getUserTier(userId: string): Promise<UserTier> {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('subscriptions')
    .select('plan')
    .eq('user_id', userId)
    .single();

  if (error || !data) return 'free';

  return data.plan === 'pro' ? 'authenticated' : 'free';
}

export async function getSession() {
  const supabase = await createClient();

  const { data: { session }, error } = await supabase.auth.getSession();

  if (error) throw error;

  return session;
}
