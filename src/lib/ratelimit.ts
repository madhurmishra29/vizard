import { Redis } from '@upstash/redis';
import { Ratelimit } from '@upstash/ratelimit';

const redis = new Redis({
  url: process.env.UPSTASH_REDIS_REST_URL!,
  token: process.env.UPSTASH_REDIS_REST_TOKEN!,
});

const limiters = {
  free: new Ratelimit({
    redis,
    limiter: Ratelimit.fixedWindow(5, '1 d'),
    prefix: 'vizard:rl:free',
  }),
  authenticated: new Ratelimit({
    redis,
    limiter: Ratelimit.fixedWindow(20, '1 d'),
    prefix: 'vizard:rl:auth',
  }),
};

export async function checkRateLimit(
  identifier: string,
  tier: 'free' | 'authenticated'
): Promise<{ success: boolean; remaining: number; reset: number }> {
  const { success, remaining, reset } = await limiters[tier].limit(identifier);
  return { success, remaining, reset };
}
