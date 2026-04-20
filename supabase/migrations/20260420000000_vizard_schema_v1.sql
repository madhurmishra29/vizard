-- =============================================================================
-- VIZARD — SUPABASE SCHEMA V2.1 (COMPLETE, PRODUCTION-READY)
-- =============================================================================
-- Covers: auth, profiles, billing, prompt versioning, conversations, messages,
-- pathway explorer, points calculator, PII scrubbing audit, moderation queue,
-- MARA referrals, compliance reviews, waitlist, feedback, disclaimer tracking,
-- data deletion requests, V2 stubs (EOI, checklists, agents, alerts, outcomes),
-- V3 stubs (documents, family accounts, API keys, device tokens).
-- =============================================================================
-- EXECUTION ORDER: Run top to bottom in one transaction.
-- DEPENDENCIES:   Supabase project with auth.users enabled.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 0. EXTENSIONS
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";       -- fuzzy occupation search
CREATE EXTENSION IF NOT EXISTS "moddatetime";    -- auto-update updated_at
CREATE EXTENSION IF NOT EXISTS "pgcrypto";       -- gen_random_uuid() + SHA-256

-- =============================================================================
-- 1. ENUMERATIONS
-- Stable, schema-critical types only.
-- Operationally flexible types (MARA triggers) live in lookup tables.
-- =============================================================================

CREATE TYPE plan_type AS ENUM (
  'free',
  'pro'
);

CREATE TYPE prompt_layer AS ENUM (
  'core',        -- Layer 1: Core Identity, sent on every call
  'knowledge',   -- Layer 2: Knowledge Injection Block, injected selectively
  'pathway',     -- Layer 3: Pathway Explorer feature prompt
  'points',      -- Layer 3: Points Calculator feature prompt
  'checklist',   -- V2: Document checklist prompts
  'agent'        -- V3: Agent-facing prompt layer
);

CREATE TYPE message_role AS ENUM (
  'user',
  'assistant',
  'system'       -- injected system turns (e.g. five-turn MARA injection)
);

CREATE TYPE pii_pattern_type AS ENUM (
  'passport',
  'tfn',
  'visa_grant',
  'dob',
  'medicare',
  'phone',
  'address'
);

CREATE TYPE moderation_review_status AS ENUM (
  'pending',
  'reviewed',
  'escalated',
  'dismissed'
);

CREATE TYPE credit_event_type AS ENUM (
  'grant',    -- credits added (signup, promo)
  'use',      -- credit consumed by a question
  'expire',   -- credits expired
  'refund'    -- V2: credit refunded on failed request
);

CREATE TYPE knowledge_query_category AS ENUM (
  'processing_time',
  'fees',
  'points_test',
  'occupation_list',
  'cut_off_scores',
  'document_requirements',   -- V2
  'agent_contact'            -- V2
);

CREATE TYPE subscription_status AS ENUM (
  'active',
  'cancelled',
  'past_due',
  'trialing',
  'paused'
);

CREATE TYPE visa_goal AS ENUM (
  'PR',
  'work',
  'study',
  'family',   -- V3 family accounts
  'other'
);

CREATE TYPE document_status AS ENUM (
  'pending',
  'uploaded',
  'parsing',
  'parsed',
  'failed',
  'expired'
);

CREATE TYPE deletion_request_status AS ENUM (
  'pending',
  'in_progress',
  'completed',
  'rejected'
);

CREATE TYPE alert_trigger_type AS ENUM (
  'visa_expiry',
  'skillselect_round',
  'occupation_list_change',
  'processing_time_change',
  'eoi_score_change'
);

-- =============================================================================
-- 2. REFERENCE / LOOKUP TABLES
-- Operationally flexible — no schema migration needed to add rows.
-- =============================================================================

-- 2.1  MARA trigger types
--      Lookup table replacing a closed enum. Compliance team can add new
--      trigger types without ALTER TYPE + maintenance window.
CREATE TABLE public.mara_trigger_types (
  code         text        PRIMARY KEY,
  label        text        NOT NULL,
  description  text,
  is_active    boolean     NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.mara_trigger_types (code, label, description) VALUES
  ('previous_refusal_or_cancellation', 'Previous Refusal or Cancellation',
    'User references a prior visa refusal or cancellation'),
  ('character_issues', 'Character Issues',
    'User query involves character requirement concerns'),
  ('health_requirements', 'Health Requirements',
    'User query involves health condition and visa implications'),
  ('merits_review_aat_ministerial', 'Merits Review / AAT / Ministerial',
    'Query involves AAT review, ministerial intervention, or merits appeal'),
  ('subclass_186_494_detail', 'Subclass 186/494 Complex Detail',
    'Query requires detailed 186 or 494 employer-sponsored pathway advice'),
  ('unlawful_overstay_expired_bridging', 'Unlawful Non-Citizen / Overstay',
    'User appears to be unlawful or on expired bridging visa'),
  ('specific_application_action_requested', 'Application Action Requested',
    'User asks AI to take a specific action on their visa application'),
  ('document_review_draft_requested', 'Document Review / Draft Requested',
    'User asks AI to review or draft visa-related documents'),
  ('high_stakes_language', 'High Stakes Language',
    'User expresses urgency or high emotional stakes around outcome'),
  ('document_pasted_for_interpretation', 'Document Pasted for Interpretation',
    'User pastes a legal or government document requesting interpretation'),
  ('five_turn_app_injection', 'Five-Turn App Injection',
    'Proactive MARA CTA injected by application after 5 turns'),
  ('urgency_flag', 'Urgency Flag',
    'Visa expiry within 60 days detected from profile');

-- 2.2  Visa subclasses — structured reference replacing free-text current_visa
CREATE TABLE public.visa_subclasses (
  subclass_code  text        PRIMARY KEY,    -- e.g. '485', '482', '189'
  name           text        NOT NULL,
  stream         text,
  category       text,                       -- 'temporary', 'permanent', 'bridging'
  is_active      boolean     NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.visa_subclasses (subclass_code, name, stream, category) VALUES
  ('485',       'Temporary Graduate Visa',             'Post-Study Work Stream',   'temporary'),
  ('482',       'Temporary Skill Shortage Visa',        NULL,                       'temporary'),
  ('189',       'Skilled Independent Visa',             NULL,                       'permanent'),
  ('190',       'Skilled Nominated Visa',               NULL,                       'permanent'),
  ('491',       'Skilled Work Regional (Provisional)',  NULL,                       'temporary'),
  ('494',       'Skilled Employer Sponsored Regional',  NULL,                       'temporary'),
  ('186',       'Employer Nomination Scheme',           NULL,                       'permanent'),
  ('500',       'Student Visa',                         NULL,                       'temporary'),
  ('820',       'Partner Visa (Temporary)',             NULL,                       'temporary'),
  ('801',       'Partner Visa (Permanent)',             NULL,                       'permanent'),
  ('600',       'Visitor Visa',                         NULL,                       'temporary'),
  ('bridging_a','Bridging Visa A',                     NULL,                       'bridging'),
  ('bridging_b','Bridging Visa B',                     NULL,                       'bridging'),
  ('bridging_c','Bridging Visa C',                     NULL,                       'bridging');

-- 2.3  ANZSCO occupations reference
--      FK target for user_profiles and EOI tables.
--      GIN trigram index enables fuzzy occupation search.
CREATE TABLE public.anzsco_occupations (
  anzsco_code   text        PRIMARY KEY CHECK (anzsco_code ~ '^\d{6}$'),
  title         text        NOT NULL,
  skill_level   integer     CHECK (skill_level BETWEEN 1 AND 5),
  is_on_mltssl  boolean     NOT NULL DEFAULT false,
  is_on_stsol   boolean     NOT NULL DEFAULT false,
  is_on_rol     boolean     NOT NULL DEFAULT false,
  is_active     boolean     NOT NULL DEFAULT true,
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_anzsco_title_trgm ON public.anzsco_occupations
  USING gin (title gin_trgm_ops);

-- 2.4  Moderation keyword categories
--      Stores category codes, not raw keyword strings, to avoid PII-adjacent storage.
CREATE TABLE public.moderation_keyword_categories (
  code         text    PRIMARY KEY,
  label        text    NOT NULL,
  flag_type    text    NOT NULL CHECK (flag_type IN ('health', 'character')),
  description  text,
  is_active    boolean NOT NULL DEFAULT true
);

-- =============================================================================
-- 3. CORE USER TABLES
-- =============================================================================

-- 3.1  Users — mirrors auth.users, minimal PII at application layer
CREATE TABLE public.users (
  id          uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email       text        NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,             -- soft delete
  purged_at   timestamptz              -- set when PII has been hard-wiped (Privacy Act)
);

-- Trigger: keep email in sync when auth.users email changes
CREATE OR REPLACE FUNCTION public.sync_user_email()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  UPDATE public.users SET email = NEW.email WHERE id = NEW.id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_user_email
  AFTER UPDATE OF email ON auth.users
  FOR EACH ROW
  WHEN (OLD.email IS DISTINCT FROM NEW.email)
  EXECUTE FUNCTION public.sync_user_email();

-- 3.2  User visa profiles
--      All fields nullable; partial profiles are valid.
--      nationality enforced as ISO 3166-1 alpha-2 (not free text).
--      goal converted to enum (not CHECK on text).
CREATE TABLE public.user_profiles (
  id                  uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid         NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  current_visa_code   text         REFERENCES public.visa_subclasses(subclass_code),
  visa_expiry         date,
  nationality         char(2)      CHECK (nationality ~ '^[A-Z]{2}$'),
  goal                visa_goal,
  occupation_title    text,
  anzsco_code         text         REFERENCES public.anzsco_occupations(anzsco_code),
  years_in_australia  numeric(4,1) CHECK (years_in_australia >= 0),
  language_preference text         NOT NULL DEFAULT 'en',
  created_at          timestamptz  NOT NULL DEFAULT now(),
  updated_at          timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON COLUMN public.user_profiles.nationality IS
  'ISO 3166-1 alpha-2 country code. Enforced by CHECK constraint. Sensitive PII.';
COMMENT ON COLUMN public.user_profiles.visa_expiry IS
  'Used for urgency detection (<60 days triggers MARA flag). Sensitive PII.';

-- =============================================================================
-- 4. DISCLAIMER TRACKING
-- MARA compliance requires demonstrable evidence that every user was shown
-- and accepted the "information not advice" disclaimer before receiving AI output.
-- =============================================================================

-- 4.1  Versioned disclaimer text
CREATE TABLE public.disclaimer_versions (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  version      text        NOT NULL UNIQUE,
  content      text        NOT NULL,
  content_hash text        NOT NULL,   -- SHA-256 of content for integrity
  active       boolean     NOT NULL DEFAULT false,
  approved_by  text,
  approved_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX disclaimer_versions_one_active
  ON public.disclaimer_versions (active)
  WHERE active = true;

-- 4.2  Every show / accept / dismiss event per user or session
CREATE TABLE public.disclaimer_events (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  session_id         text,
  disclaimer_version text        NOT NULL REFERENCES public.disclaimer_versions(version),
  event_type         text        NOT NULL CHECK (event_type IN ('shown', 'accepted', 'dismissed')),
  shown_at           timestamptz NOT NULL DEFAULT now(),
  accepted_at        timestamptz,
  conversation_id    uuid,        -- FK added after conversations table
  ip_hash            text,        -- hashed IP for legal evidence, never raw IP
  CONSTRAINT chk_disclaimer_user_or_session CHECK (
    user_id IS NOT NULL OR session_id IS NOT NULL
  )
);

COMMENT ON TABLE public.disclaimer_events IS
  'Every disclaimer shown/accepted/dismissed event. Required for MARA compliance.
   Never delete rows. After user purge: ip_hash and session_id wiped by
   purge_user_pii(); timestamps and disclaimer_version retained as anonymised
   compliance evidence.';

-- =============================================================================
-- 5. SUBSCRIPTION & BILLING
-- =============================================================================

-- 5.1  Subscriptions — one active row per user
CREATE TABLE public.subscriptions (
  id                     uuid                PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                uuid                NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  plan                   plan_type           NOT NULL DEFAULT 'free',
  status                 subscription_status NOT NULL DEFAULT 'active',
  credits_remaining      integer             NOT NULL DEFAULT 3 CHECK (credits_remaining >= 0),
  stripe_customer_id     text                UNIQUE,
  stripe_subscription_id text                UNIQUE,
  current_period_start   timestamptz,
  current_period_end     timestamptz,
  cancelled_at           timestamptz,
  created_at             timestamptz         NOT NULL DEFAULT now(),
  updated_at             timestamptz         NOT NULL DEFAULT now()
);

COMMENT ON COLUMN public.subscriptions.credits_remaining IS
  'Free tier only. 3 on signup. Pro tier: ignored — unlimited access.';

-- 5.2  Credit transactions — immutable audit log
CREATE TABLE public.credit_transactions (
  id               uuid               PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid               NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  event_type       credit_event_type  NOT NULL,
  amount           integer            NOT NULL,
  balance_after    integer            NOT NULL CHECK (balance_after >= 0),
  conversation_id  uuid,              -- FK added after conversations table
  note             text,
  created_at       timestamptz        NOT NULL DEFAULT now()
);

-- =============================================================================
-- 6. PROMPT VERSIONING
-- Immutable audit trail. content_hash enforces integrity.
-- compliance_approved required before activating core/knowledge layers.
-- =============================================================================

CREATE TABLE public.prompts (
  id                   uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  version              text           NOT NULL,
  layer                prompt_layer   NOT NULL,
  content              text           NOT NULL,
  content_hash         text           NOT NULL,   -- SHA-256; computed on insert by trigger
  change_summary       text,
  compliance_approved  boolean        NOT NULL DEFAULT false,
  approved_by          text,
  approved_at          timestamptz,
  created_by           text           NOT NULL,
  active               boolean        NOT NULL DEFAULT false,
  created_at           timestamptz    NOT NULL DEFAULT now(),
  UNIQUE (layer, version)
);

CREATE UNIQUE INDEX prompts_one_active_per_layer
  ON public.prompts (layer)
  WHERE active = true;

-- Compute content_hash on insert
CREATE OR REPLACE FUNCTION public.set_prompt_content_hash()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public AS $$
BEGIN
  NEW.content_hash := encode(extensions.digest(NEW.content, 'sha256'), 'hex');
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prompt_content_hash
  BEFORE INSERT ON public.prompts
  FOR EACH ROW EXECUTE FUNCTION public.set_prompt_content_hash();

-- Enforce compliance approval + prevent content modification post-approval
CREATE OR REPLACE FUNCTION public.enforce_prompt_compliance_approval()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public AS $$
BEGIN
  IF NEW.active = true
     AND NEW.layer IN ('core', 'knowledge')
     AND NEW.compliance_approved = false
  THEN
    RAISE EXCEPTION
      'Cannot activate a core or knowledge prompt without compliance_approved = true. '
      'Have a migration lawyer review and approve before launch.';
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.compliance_approved = true
     AND NEW.content != OLD.content
  THEN
    RAISE EXCEPTION
      'Cannot modify content of a compliance-approved prompt. '
      'Create a new version row instead.';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prompt_compliance_approval
  BEFORE INSERT OR UPDATE ON public.prompts
  FOR EACH ROW EXECUTE FUNCTION public.enforce_prompt_compliance_approval();

-- Helper: safely swap active prompt for a given layer (SECURITY DEFINER)
CREATE OR REPLACE FUNCTION public.activate_prompt(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_layer prompt_layer;
BEGIN
  SELECT layer INTO v_layer FROM public.prompts WHERE id = p_id;
  IF v_layer IS NULL THEN
    RAISE EXCEPTION 'Prompt % not found.', p_id;
  END IF;
  UPDATE public.prompts SET active = false WHERE layer = v_layer AND active = true;
  UPDATE public.prompts SET active = true  WHERE id = p_id;
END;
$$;

-- =============================================================================
-- 7. WAITLIST
-- Referral mechanic + Instagram reel UTM attribution.
-- referral_count denormalised and maintained by trigger (replaces correlated subquery).
-- =============================================================================

CREATE TABLE public.waitlist (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  email                 text        NOT NULL UNIQUE,
  referral_code         text        NOT NULL UNIQUE
                          DEFAULT substr(md5(gen_random_uuid()::text), 1, 8),
  referred_by           text        REFERENCES public.waitlist(referral_code)
                          ON DELETE SET NULL,
  referral_count        integer     NOT NULL DEFAULT 0,
  utm_source            text,
  utm_medium            text,
  utm_campaign          text,
  utm_content           text,
  instagram_reel_id     text,
  joined_at             timestamptz NOT NULL DEFAULT now(),
  invited_at            timestamptz,
  converted_at          timestamptz,
  user_id               uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  deletion_requested_at timestamptz
);

COMMENT ON COLUMN public.waitlist.instagram_reel_id IS
  'Reel identifier from UTM content parameter. Attributes signups to specific reels.';
COMMENT ON COLUMN public.waitlist.deletion_requested_at IS
  'Privacy Act: user-requested removal from waitlist.';

-- Increment referral_count on the referrer when a new entry cites their code
CREATE OR REPLACE FUNCTION public.increment_referral_count()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public AS $$
BEGIN
  IF NEW.referred_by IS NOT NULL THEN
    UPDATE public.waitlist
    SET referral_count = referral_count + 1
    WHERE referral_code = NEW.referred_by;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_increment_referral_count
  AFTER INSERT ON public.waitlist
  FOR EACH ROW EXECUTE FUNCTION public.increment_referral_count();

-- =============================================================================
-- 8. CONVERSATIONS
-- active_core_prompt_id is a UUID FK (not a loose text version string).
-- disclaimer_accepted_at enforces MARA requirement at conversation level.
-- ai_model_version recorded for compliance audit trail.
-- mara_injection_fired_at_turn removed — see mara_injection_events table.
-- =============================================================================

CREATE TABLE public.conversations (
  id                          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                     uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  session_id                  text,
  is_persistent               boolean     NOT NULL DEFAULT false,
  active_core_prompt_id       uuid        REFERENCES public.prompts(id),
  active_knowledge_prompt_id  uuid        REFERENCES public.prompts(id),
  ai_model_version            text        NOT NULL DEFAULT 'claude-sonnet-4-20250514',
  disclaimer_accepted_at      timestamptz,
  disclaimer_version          text        REFERENCES public.disclaimer_versions(version),
  -- Snapshot stored as JSONB; wiped by purge_user_pii() on hard-delete
  user_profile_snapshot       jsonb,
  tier_snapshot               jsonb,
  turn_count                  integer     NOT NULL DEFAULT 0,
  message_pair_count          integer     NOT NULL DEFAULT 0,
  language_detected           text        NOT NULL DEFAULT 'en',
  ended_at                    timestamptz,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_user_or_session CHECK (
    user_id IS NOT NULL OR session_id IS NOT NULL
  )
);

COMMENT ON COLUMN public.conversations.user_profile_snapshot IS
  'Snapshot of [USER PROFILE] at conversation start. Contains PII.
   MUST be wiped (set to NULL) by purge_user_pii() on user hard-delete.
   Privacy Act 1988 compliance obligation.';
COMMENT ON COLUMN public.conversations.disclaimer_accepted_at IS
  'Timestamp of disclaimer acceptance for this conversation.
   NULL = disclaimer not yet accepted. Application layer MUST block AI
   responses until this is set. MARA compliance requirement.';
COMMENT ON COLUMN public.conversations.ai_model_version IS
  'AI model version string at conversation start. Required for compliance audit.';

-- =============================================================================
-- 9. MESSAGES
-- Written for Pro (persistent) conversations only.
-- Free tier: messages exist in-session only and are NOT written here.
-- ai_disclaimer_appended confirms disclaimer was appended to this response.
-- mara_trigger_reasons is a text[] (not enum) referencing mara_trigger_types.code.
-- Referential integrity enforced by trg_validate_mara_trigger_reasons (below).
-- =============================================================================

CREATE TABLE public.messages (
  id                        uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id           uuid          NOT NULL
                              REFERENCES public.conversations(id) ON DELETE CASCADE,
  message_index             integer       NOT NULL,
  role                      message_role  NOT NULL,
  content                   text          NOT NULL,
  content_hash              text,         -- SHA-256 set on INSERT for assistant messages
  pii_scrubbed              boolean       NOT NULL DEFAULT false,
  ai_disclaimer_appended    boolean,      -- NULL for user/system; true/false for assistant
  knowledge_block_injected  boolean       NOT NULL DEFAULT false,
  knowledge_query_category  knowledge_query_category,
  mara_trigger_fired        boolean       NOT NULL DEFAULT false,
  mara_trigger_reasons      text[],       -- validated against mara_trigger_types.code
  system_injection          boolean       NOT NULL DEFAULT false,
  created_at                timestamptz   NOT NULL DEFAULT now(),
  UNIQUE (conversation_id, message_index)
);

COMMENT ON TABLE public.messages IS
  'Pro tier only. Free tier messages are session-only and must never be written here.';
COMMENT ON COLUMN public.messages.ai_disclaimer_appended IS
  'For assistant messages only. true = disclaimer appended. false = omitted (should
   never happen; triggers compliance alert). NULL = not an assistant message.';
COMMENT ON COLUMN public.messages.mara_trigger_reasons IS
  'Text array of mara_trigger_types.code values. Referential integrity enforced by
   trg_validate_mara_trigger_reasons trigger. Text array (not enum) allows new
   trigger types to be added without a schema migration.';

-- Compute content_hash for assistant messages on insert
CREATE OR REPLACE FUNCTION public.set_message_content_hash()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public AS $$
BEGIN
  IF NEW.role = 'assistant' THEN
    NEW.content_hash := encode(extensions.digest(NEW.content, 'sha256'), 'hex');
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_message_content_hash
  BEFORE INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.set_message_content_hash();

-- Validate every element of mara_trigger_reasons against mara_trigger_types
-- Closes the referential integrity gap created by replacing the closed enum.
CREATE OR REPLACE FUNCTION public.validate_mara_trigger_reasons()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public AS $$
DECLARE
  v_code  text;
  v_valid boolean;
BEGIN
  IF NEW.mara_trigger_reasons IS NULL
     OR array_length(NEW.mara_trigger_reasons, 1) IS NULL
  THEN
    RETURN NEW;
  END IF;

  FOREACH v_code IN ARRAY NEW.mara_trigger_reasons
  LOOP
    SELECT EXISTS (
      SELECT 1 FROM public.mara_trigger_types
      WHERE code = v_code AND is_active = true
    ) INTO v_valid;

    IF NOT v_valid THEN
      RAISE EXCEPTION
        'Invalid mara_trigger_reason: ''%'' does not exist in mara_trigger_types '
        'or is inactive. Check application layer for typo.',
        v_code;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_mara_trigger_reasons
  BEFORE INSERT OR UPDATE ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.validate_mara_trigger_reasons();

COMMENT ON TRIGGER trg_validate_mara_trigger_reasons ON public.messages IS
  'Enforces referential integrity on mara_trigger_reasons text[].
   Each element must exist as an active code in mara_trigger_types.
   Replaces the FK guarantee previously provided by a closed enum.';

-- =============================================================================
-- 10. MARA INJECTION EVENTS
-- Append-only log of every five-turn MARA injection event per conversation.
-- Replaces the single mara_injection_fired_at_turn column on conversations
-- which only retained the most recent firing, losing historical audit depth.
-- =============================================================================

CREATE TABLE public.mara_injection_events (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  uuid        NOT NULL
                     REFERENCES public.conversations(id) ON DELETE CASCADE,
  turn_number      integer     NOT NULL,
  trigger_type     text        NOT NULL REFERENCES public.mara_trigger_types(code),
  injected_at      timestamptz NOT NULL DEFAULT now()
);

-- =============================================================================
-- 11. CONVERSATION SUMMARIES
-- Append-only. is_active flag replaced the UNIQUE constraint so all historical
-- summaries are retained for audit. Bounded to last 10 per conversation by
-- trg_enforce_summary_retention to prevent unbounded growth at scale.
-- =============================================================================

CREATE TABLE public.conversation_summaries (
  id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id         uuid        NOT NULL
                            REFERENCES public.conversations(id) ON DELETE CASCADE,
  summary_text            text        NOT NULL,
  messages_covered_start  integer     NOT NULL,
  messages_covered_end    integer     NOT NULL,
  is_active               boolean     NOT NULL DEFAULT true,
  generated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX conv_summaries_one_active
  ON public.conversation_summaries (conversation_id)
  WHERE is_active = true;

-- Deactivate previous summary when a new one is inserted
CREATE OR REPLACE FUNCTION public.deactivate_previous_summary()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public AS $$
BEGIN
  UPDATE public.conversation_summaries
  SET is_active = false
  WHERE conversation_id = NEW.conversation_id
    AND id != NEW.id
    AND is_active = true;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deactivate_previous_summary
  AFTER INSERT ON public.conversation_summaries
  FOR EACH ROW EXECUTE FUNCTION public.deactivate_previous_summary();

-- Bound summary history to 10 rows per conversation.
-- Fires after each INSERT. Deletes the oldest beyond the 10 most recent.
-- Adjust LIMIT if audit retention requirements change.
CREATE OR REPLACE FUNCTION public.enforce_summary_retention()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public AS $$
BEGIN
  DELETE FROM public.conversation_summaries
  WHERE conversation_id = NEW.conversation_id
    AND id NOT IN (
      SELECT id
      FROM public.conversation_summaries
      WHERE conversation_id = NEW.conversation_id
      ORDER BY generated_at DESC
      LIMIT 10
    );
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_summary_retention
  AFTER INSERT ON public.conversation_summaries
  FOR EACH ROW EXECUTE FUNCTION public.enforce_summary_retention();

COMMENT ON TABLE public.conversation_summaries IS
  'Append-only. New summaries are inserted, not updated. Previous summaries set
   is_active=false via trigger. Capped at 10 rows per conversation by
   trg_enforce_summary_retention. All retained summaries are AI-generated outputs
   subject to the same MARA compliance rules as messages.';

-- =============================================================================
-- 12. PII SCRUBBING AUDIT
-- Audit log only. Never stores original content.
-- =============================================================================

CREATE TABLE public.pii_scrub_events (
  id               uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  uuid              NOT NULL REFERENCES public.conversations(id),
  message_index    integer           NOT NULL,
  pattern_type     pii_pattern_type  NOT NULL,
  scrubbed_at      timestamptz       NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.pii_scrub_events IS
  'Audit log for PII detection and scrubbing. Logged to match Sentry events.
   NEVER store original PII content here — log the pattern type only.';

-- =============================================================================
-- 13. MODERATION QUEUE
-- triggered_keyword_codes stores category codes (FK to lookup), not raw strings.
-- content_excerpt stored only for free-tier sessions where the message is not
-- persisted in the messages table. Reviewed and purged after review.
-- =============================================================================

CREATE TABLE public.moderation_queue (
  id                      uuid                      PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id         uuid                      REFERENCES public.conversations(id),
  message_index           integer,
  flag_type               text                      NOT NULL
                            CHECK (flag_type IN ('health', 'character')),
  triggered_keyword_codes text[]                    NOT NULL DEFAULT '{}',
  content_excerpt         text,
  review_status           moderation_review_status  NOT NULL DEFAULT 'pending',
  reviewed_by             uuid                      REFERENCES public.users(id),
  reviewed_at             timestamptz,
  reviewer_notes          text,
  flagged_at              timestamptz               NOT NULL DEFAULT now()
);

COMMENT ON COLUMN public.moderation_queue.triggered_keyword_codes IS
  'Array of moderation_keyword_categories.code values. Category references, not
   raw keyword strings, to avoid PII-adjacent storage.';
COMMENT ON COLUMN public.moderation_queue.content_excerpt IS
  'First 200 characters of flagged content. Required for free-tier sessions where
   the message is not persisted in the messages table. Purged after review.';

-- =============================================================================
-- 14. MARA REFERRAL EVENTS
-- Tracks every MARA CTA surfacing and whether the user clicked through.
-- trigger_type references mara_trigger_types.code (lookup table, not enum).
-- Never suppressed by paywall.
-- =============================================================================

CREATE TABLE public.mara_referral_events (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  uuid        REFERENCES public.conversations(id),
  message_index    integer,
  trigger_type     text        NOT NULL REFERENCES public.mara_trigger_types(code),
  cta_shown        boolean     NOT NULL DEFAULT true,
  cta_clicked      boolean     NOT NULL DEFAULT false,
  clicked_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.mara_referral_events IS
  'Every MARA CTA surfacing is logged. Measures referral rate by trigger type.
   Never suppressed by paywall.';

-- =============================================================================
-- 15. PATHWAY EXPLORER RESULTS
-- Full JSON input/output for Pro. Session-only for free tier.
-- input_profile contains PII; wiped by purge_user_pii() on hard-delete.
-- =============================================================================

CREATE TABLE public.pathway_results (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  conversation_id  uuid        REFERENCES public.conversations(id),
  session_id       text,
  input_profile    jsonb       NOT NULL,
  result           jsonb       NOT NULL,
  prompt_version   text        NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_pathway_user_or_session CHECK (
    user_id IS NOT NULL OR session_id IS NOT NULL
  )
);

COMMENT ON COLUMN public.pathway_results.input_profile IS
  'Contains PII. MUST be wiped (set to {}) by purge_user_pii() on user hard-delete.';
COMMENT ON COLUMN public.pathway_results.result IS
  'Full pathway explorer JSON output. Includes pathways[], summary,
   common_next_step, and data_caveat.';

-- =============================================================================
-- 16. POINTS CALCULATOR RESULTS
-- =============================================================================

CREATE TABLE public.points_results (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  conversation_id   uuid        REFERENCES public.conversations(id),
  session_id        text,
  input_data        jsonb       NOT NULL,
  total_points      integer     NOT NULL CHECK (total_points >= 0 AND total_points <= 130),
  points_breakdown  jsonb       NOT NULL,
  top_improvements  jsonb       NOT NULL,
  summary           text        NOT NULL,
  competitiveness   text        NOT NULL,
  prompt_version    text        NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_points_user_or_session CHECK (
    user_id IS NOT NULL OR session_id IS NOT NULL
  )
);

COMMENT ON COLUMN public.points_results.input_data IS
  'Contains PII. MUST be wiped (set to {}) by purge_user_pii() on user hard-delete.';
COMMENT ON COLUMN public.points_results.total_points IS
  'Max theoretical score is ~130 pts. Check constraint guards against data errors.';

-- =============================================================================
-- 17. FEEDBACK
-- INSERT policy verifies conversation ownership to prevent cross-user submissions.
-- Duplicate guard: UNIQUE on (conversation_id, message_index, user_id).
-- =============================================================================

CREATE TABLE public.feedback (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  uuid        REFERENCES public.conversations(id),
  message_index    integer,
  user_id          uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  session_id       text,
  rating           smallint    NOT NULL CHECK (rating IN (1, -1)),
  comment          text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (conversation_id, message_index, user_id)
);

-- =============================================================================
-- 18. PRIVACY ACT COMPLIANCE
-- data_deletion_requests: logged, tracked, auditable.
-- Rows retained permanently for legal audit trail even after completion.
-- =============================================================================

CREATE TABLE public.data_deletion_requests (
  id              uuid                    PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid                    REFERENCES public.users(id) ON DELETE SET NULL,
  email           text                    NOT NULL,
  request_type    text                    NOT NULL
                    CHECK (request_type IN ('delete', 'export', 'rectify')),
  status          deletion_request_status NOT NULL DEFAULT 'pending',
  requested_at    timestamptz             NOT NULL DEFAULT now(),
  acknowledged_at timestamptz,
  completed_at    timestamptz,
  notes           text,
  handled_by      text
);

COMMENT ON TABLE public.data_deletion_requests IS
  'Privacy Act 1988 compliance. Log all user data requests.
   Must be actioned within 30 days. Rows retained permanently for legal audit.';

-- =============================================================================
-- 19. MONTHLY COMPLIANCE REVIEWS
-- Trigger prevents marking complete with any unchecked items.
-- =============================================================================

CREATE TABLE public.monthly_reviews (
  id                              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  review_month                    date        NOT NULL UNIQUE,
  reviewer_name                   text        NOT NULL,
  processing_times_updated        boolean     NOT NULL DEFAULT false,
  fees_updated                    boolean     NOT NULL DEFAULT false,
  skillselect_cutoffs_checked     boolean     NOT NULL DEFAULT false,
  occupation_lists_checked        boolean     NOT NULL DEFAULT false,
  sentry_pii_logs_reviewed        boolean     NOT NULL DEFAULT false,
  moderation_queue_reviewed       boolean     NOT NULL DEFAULT false,
  policy_announcements_checked    boolean     NOT NULL DEFAULT false,
  model_behaviour_issues_reviewed boolean     NOT NULL DEFAULT false,
  disclaimer_events_reviewed      boolean     NOT NULL DEFAULT false,
  new_knowledge_block_version     text,
  notes                           text,
  completed_at                    timestamptz,
  created_at                      timestamptz NOT NULL DEFAULT now()
);

-- Prevent marking complete with any unchecked items
CREATE OR REPLACE FUNCTION public.enforce_review_completeness()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public AS $$
BEGIN
  IF NEW.completed_at IS NOT NULL AND (
    NEW.processing_times_updated        = false OR
    NEW.fees_updated                    = false OR
    NEW.skillselect_cutoffs_checked     = false OR
    NEW.occupation_lists_checked        = false OR
    NEW.sentry_pii_logs_reviewed        = false OR
    NEW.moderation_queue_reviewed       = false OR
    NEW.policy_announcements_checked    = false OR
    NEW.model_behaviour_issues_reviewed = false OR
    NEW.disclaimer_events_reviewed      = false
  ) THEN
    RAISE EXCEPTION
      'Cannot mark monthly review as complete — one or more checklist items are false.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_review_completeness
  BEFORE INSERT OR UPDATE ON public.monthly_reviews
  FOR EACH ROW EXECUTE FUNCTION public.enforce_review_completeness();

COMMENT ON TABLE public.monthly_reviews IS
  'Enforces the monthly review checklist. completed_at cannot be set unless all
   boolean checklist fields are true. Enforced by trg_enforce_review_completeness.';

-- =============================================================================
-- 20. V2 STUB TABLES
-- Structurally present to ensure forward compatibility without breaking redesigns.
-- =============================================================================

-- 20.1  EOI snapshots + comparisons
CREATE TABLE public.eoi_snapshots (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid        REFERENCES public.users(id) ON DELETE CASCADE,
  subclass_code    text        REFERENCES public.visa_subclasses(subclass_code),
  round_date       date        NOT NULL,
  lowest_score     integer,
  state            text,
  occupation_code  text        REFERENCES public.anzsco_occupations(anzsco_code),
  invitation_count integer,
  source_url       text,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.eoi_comparisons (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid        REFERENCES public.users(id) ON DELETE CASCADE,
  snapshot_ids uuid[]      NOT NULL,
  user_score   integer,
  analysis     jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- 20.2  Document checklists
CREATE TABLE public.document_checklists (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid        REFERENCES public.users(id) ON DELETE CASCADE,
  subclass_code  text        REFERENCES public.visa_subclasses(subclass_code),
  title          text        NOT NULL,
  status         text        NOT NULL DEFAULT 'in_progress'
                   CHECK (status IN ('in_progress', 'complete', 'archived')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.checklist_items (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  checklist_id  uuid        NOT NULL
                  REFERENCES public.document_checklists(id) ON DELETE CASCADE,
  item_label    text        NOT NULL,
  is_required   boolean     NOT NULL DEFAULT true,
  is_complete   boolean     NOT NULL DEFAULT false,
  notes         text,
  sort_order    integer     NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- 20.3  Agent marketplace (basic V2 skeleton)
CREATE TABLE public.agents (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  mara_number      text        NOT NULL UNIQUE,
  business_name    text        NOT NULL,
  display_name     text,
  specialisations  text[],
  states           text[],
  languages        text[],
  website_url      text,
  email_contact    text,
  is_verified      boolean     NOT NULL DEFAULT false,
  is_active        boolean     NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.agent_engagements (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  agent_id         uuid        NOT NULL REFERENCES public.agents(id),
  referral_source  uuid        REFERENCES public.mara_referral_events(id),
  status           text        NOT NULL DEFAULT 'referred'
                     CHECK (status IN ('referred', 'contacted', 'engaged', 'completed')),
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- 20.4  Alerts
CREATE TABLE public.alert_subscriptions (
  id            uuid               PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid               NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  trigger_type  alert_trigger_type NOT NULL,
  config        jsonb,
  is_active     boolean            NOT NULL DEFAULT true,
  created_at    timestamptz        NOT NULL DEFAULT now()
);

CREATE TABLE public.user_alerts (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  subscription_id  uuid        REFERENCES public.alert_subscriptions(id) ON DELETE SET NULL,
  title            text        NOT NULL,
  body             text        NOT NULL,
  is_read          boolean     NOT NULL DEFAULT false,
  read_at          timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- 20.5  Visa outcomes (anonymised aggregate data — no user_id by design)
CREATE TABLE public.visa_outcomes (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  subclass_code    text        REFERENCES public.visa_subclasses(subclass_code),
  anzsco_code      text        REFERENCES public.anzsco_occupations(anzsco_code),
  state            text,
  outcome          text        NOT NULL CHECK (outcome IN ('granted', 'refused', 'withdrawn')),
  processing_days  integer,
  lodgement_year   integer,
  created_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.visa_outcomes IS
  'Anonymised aggregate outcomes data. Deliberately no user_id column.
   Must never be linked back to individual users.';

-- =============================================================================
-- 21. V3 STUB TABLES
-- =============================================================================

-- 21.1  Document uploads + AI parsing
CREATE TABLE public.documents (
  id                uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid            REFERENCES public.users(id) ON DELETE CASCADE,
  family_member_id  uuid,           -- FK added after family_members (below)
  storage_path      text,           -- Supabase Storage bucket path
  filename          text            NOT NULL,
  mime_type         text            NOT NULL,
  file_size_bytes   bigint,
  document_type     text,
  status            document_status NOT NULL DEFAULT 'pending',
  parse_result      jsonb,
  prompt_version    text,
  expires_at        date,
  created_at        timestamptz     NOT NULL DEFAULT now(),
  updated_at        timestamptz     NOT NULL DEFAULT now()
);

CREATE TABLE public.document_parse_jobs (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id   uuid        NOT NULL REFERENCES public.documents(id) ON DELETE CASCADE,
  status        text        NOT NULL DEFAULT 'queued'
                  CHECK (status IN ('queued', 'processing', 'completed', 'failed')),
  model_version text,
  started_at    timestamptz,
  completed_at  timestamptz,
  error_message text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- 21.2  Family accounts
CREATE TABLE public.family_groups (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id   uuid        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  name       text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.family_members (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  family_group_id   uuid        NOT NULL
                      REFERENCES public.family_groups(id) ON DELETE CASCADE,
  user_id           uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  name              text,
  relationship      text,
  date_of_birth     date,
  nationality       char(2),
  current_visa_code text        REFERENCES public.visa_subclasses(subclass_code),
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- Now that family_members exists, add the FK on documents
ALTER TABLE public.documents
  ADD CONSTRAINT fk_document_family_member
  FOREIGN KEY (family_member_id) REFERENCES public.family_members(id) ON DELETE SET NULL;

-- 21.3  Agent API keys
CREATE TABLE public.api_keys (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id     uuid        NOT NULL REFERENCES public.agents(id) ON DELETE CASCADE,
  key_hash     text        NOT NULL UNIQUE,   -- store hash only, never plaintext
  key_prefix   text        NOT NULL,          -- first 8 chars for display
  scopes       text[]      NOT NULL DEFAULT '{}',
  rate_limit   integer     NOT NULL DEFAULT 100,
  is_active    boolean     NOT NULL DEFAULT true,
  last_used_at timestamptz,
  expires_at   timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- 21.4  Device tokens for push notifications
CREATE TABLE public.device_tokens (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  token      text        NOT NULL UNIQUE,
  platform   text        NOT NULL CHECK (platform IN ('ios', 'android', 'web')),
  is_active  boolean     NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- =============================================================================
-- 22. DEFERRED FOREIGN KEY CONSTRAINTS
-- Added after all tables exist to avoid ordering issues.
-- =============================================================================

ALTER TABLE public.credit_transactions
  ADD CONSTRAINT fk_credit_conversation
  FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE SET NULL;

ALTER TABLE public.disclaimer_events
  ADD CONSTRAINT fk_disclaimer_conversation
  FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE SET NULL;

-- =============================================================================
-- 23. INDEXES
-- =============================================================================

-- Users
CREATE INDEX idx_users_email          ON public.users(email);
CREATE INDEX idx_users_deleted_at     ON public.users(deleted_at)  WHERE deleted_at IS NOT NULL;
CREATE INDEX idx_users_purged_at      ON public.users(purged_at)   WHERE purged_at  IS NOT NULL;

-- User profiles
CREATE INDEX idx_profiles_visa_expiry ON public.user_profiles(visa_expiry)
  WHERE visa_expiry IS NOT NULL;
CREATE INDEX idx_profiles_anzsco      ON public.user_profiles(anzsco_code)
  WHERE anzsco_code IS NOT NULL;
CREATE INDEX idx_profiles_occ_trgm    ON public.user_profiles
  USING gin (occupation_title gin_trgm_ops)
  WHERE occupation_title IS NOT NULL;

-- Subscriptions
CREATE INDEX idx_subs_plan            ON public.subscriptions(plan);
CREATE INDEX idx_subs_stripe_cust     ON public.subscriptions(stripe_customer_id)
  WHERE stripe_customer_id IS NOT NULL;
CREATE INDEX idx_subs_user_plan       ON public.subscriptions(user_id, plan);

-- Prompts
CREATE INDEX idx_prompts_layer_active ON public.prompts(layer, active);
CREATE INDEX idx_prompts_layer_ver    ON public.prompts(layer, version);

-- Waitlist
CREATE INDEX idx_waitlist_referral    ON public.waitlist(referral_code);
CREATE INDEX idx_waitlist_reel        ON public.waitlist(instagram_reel_id)
  WHERE instagram_reel_id IS NOT NULL;
CREATE INDEX idx_waitlist_utm         ON public.waitlist(utm_campaign, utm_source);
CREATE INDEX idx_waitlist_pending     ON public.waitlist(converted_at)
  WHERE converted_at IS NULL;

-- Disclaimer events
CREATE INDEX idx_disclaimer_user      ON public.disclaimer_events(user_id)
  WHERE user_id IS NOT NULL;
CREATE INDEX idx_disclaimer_conv      ON public.disclaimer_events(conversation_id)
  WHERE conversation_id IS NOT NULL;
CREATE INDEX idx_disclaimer_version   ON public.disclaimer_events(disclaimer_version);

-- Conversations
CREATE INDEX idx_conv_user_id         ON public.conversations(user_id);
CREATE INDEX idx_conv_user_created    ON public.conversations(user_id, created_at DESC);
CREATE INDEX idx_conv_session_id      ON public.conversations(session_id)
  WHERE session_id IS NOT NULL;
CREATE INDEX idx_conv_persistent      ON public.conversations(is_persistent)
  WHERE is_persistent = true;
CREATE INDEX idx_conv_no_disclaimer   ON public.conversations(disclaimer_accepted_at)
  WHERE disclaimer_accepted_at IS NULL;

-- Messages
CREATE INDEX idx_msg_conv_index       ON public.messages(conversation_id, message_index);
CREATE INDEX idx_msg_conv_role        ON public.messages(conversation_id, role);
CREATE INDEX idx_msg_mara_fired       ON public.messages(conversation_id)
  WHERE mara_trigger_fired = true;
CREATE INDEX idx_msg_no_disclaimer    ON public.messages(conversation_id)
  WHERE ai_disclaimer_appended = false AND role = 'assistant';

-- MARA injection events
CREATE INDEX idx_mara_injection_conv  ON public.mara_injection_events(conversation_id);

-- PII scrub events
CREATE INDEX idx_pii_conversation     ON public.pii_scrub_events(conversation_id);
CREATE INDEX idx_pii_pattern          ON public.pii_scrub_events(pattern_type);

-- Moderation queue
CREATE INDEX idx_mod_status           ON public.moderation_queue(review_status)
  WHERE review_status = 'pending';
CREATE INDEX idx_mod_flag_type        ON public.moderation_queue(flag_type);
CREATE INDEX idx_mod_conversation     ON public.moderation_queue(conversation_id);

-- MARA referral events
CREATE INDEX idx_mara_conversation    ON public.mara_referral_events(conversation_id);
CREATE INDEX idx_mara_trigger_type    ON public.mara_referral_events(trigger_type);
CREATE INDEX idx_mara_clicked         ON public.mara_referral_events(cta_clicked)
  WHERE cta_clicked = true;

-- Conversation summaries
CREATE INDEX idx_summaries_conv       ON public.conversation_summaries(conversation_id, generated_at DESC);

-- Pathway / Points
CREATE INDEX idx_pathway_user         ON public.pathway_results(user_id, created_at DESC);
CREATE INDEX idx_pathway_session      ON public.pathway_results(session_id)
  WHERE session_id IS NOT NULL;
CREATE INDEX idx_points_user          ON public.points_results(user_id, created_at DESC);
CREATE INDEX idx_points_total         ON public.points_results(total_points);

-- Feedback
CREATE INDEX idx_feedback_conv        ON public.feedback(conversation_id);
CREATE INDEX idx_feedback_rating      ON public.feedback(rating);

-- Monthly reviews
CREATE INDEX idx_reviews_month        ON public.monthly_reviews(review_month DESC);
CREATE INDEX idx_reviews_incomplete   ON public.monthly_reviews(completed_at)
  WHERE completed_at IS NULL;

-- Alerts
CREATE INDEX idx_alerts_user_unread   ON public.user_alerts(user_id, is_read)
  WHERE is_read = false;

-- Documents (V3)
CREATE INDEX idx_documents_user       ON public.documents(user_id, created_at DESC);
CREATE INDEX idx_documents_status     ON public.documents(status);

-- EOI
CREATE INDEX idx_eoi_snapshots_user   ON public.eoi_snapshots(user_id, round_date DESC);
CREATE INDEX idx_eoi_comparisons_user ON public.eoi_comparisons(user_id, created_at DESC);

-- Data deletion requests
CREATE INDEX idx_deletion_pending     ON public.data_deletion_requests(status)
  WHERE status IN ('pending', 'in_progress');

-- =============================================================================
-- 24. UPDATED_AT TRIGGERS
-- =============================================================================

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE TRIGGER trg_subs_updated_at
  BEFORE UPDATE ON public.subscriptions
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE TRIGGER trg_conv_updated_at
  BEFORE UPDATE ON public.conversations
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE TRIGGER trg_checklists_updated_at
  BEFORE UPDATE ON public.document_checklists
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE TRIGGER trg_checklist_items_updated_at
  BEFORE UPDATE ON public.checklist_items
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE TRIGGER trg_agents_updated_at
  BEFORE UPDATE ON public.agents
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE TRIGGER trg_documents_updated_at
  BEFORE UPDATE ON public.documents
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

CREATE TRIGGER trg_device_tokens_updated_at
  BEFORE UPDATE ON public.device_tokens
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- =============================================================================
-- 25. ROW LEVEL SECURITY
-- =============================================================================

-- Enable RLS on every table
ALTER TABLE public.users                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profiles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_transactions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.disclaimer_versions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.disclaimer_events        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mara_injection_events    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversation_summaries   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pii_scrub_events         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_queue         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mara_referral_events     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pathway_results          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.points_results           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feedback                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.data_deletion_requests   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.monthly_reviews          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prompts                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.waitlist                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mara_trigger_types       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.visa_subclasses          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.anzsco_occupations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_keyword_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eoi_snapshots            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.eoi_comparisons          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_checklists      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.checklist_items          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agents                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_engagements        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.alert_subscriptions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_alerts              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.visa_outcomes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documents                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_parse_jobs      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_groups            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_members           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_keys                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_tokens            ENABLE ROW LEVEL SECURITY;

-- Force RLS on compliance-critical tables so table owners cannot bypass
ALTER TABLE public.prompts               FORCE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_queue      FORCE ROW LEVEL SECURITY;
ALTER TABLE public.disclaimer_events     FORCE ROW LEVEL SECURITY;
ALTER TABLE public.messages              FORCE ROW LEVEL SECURITY;
ALTER TABLE public.monthly_reviews       FORCE ROW LEVEL SECURITY;
ALTER TABLE public.pii_scrub_events      FORCE ROW LEVEL SECURITY;

-- ---- Reference data: readable by authenticated, writable by service role only ----
CREATE POLICY visa_subclasses_select ON public.visa_subclasses
  FOR SELECT TO authenticated USING (true);

CREATE POLICY anzsco_select ON public.anzsco_occupations
  FOR SELECT TO authenticated USING (true);

CREATE POLICY mara_triggers_select ON public.mara_trigger_types
  FOR SELECT TO authenticated USING (is_active = true);

CREATE POLICY disclaimer_versions_select ON public.disclaimer_versions
  FOR SELECT TO authenticated USING (true);

CREATE POLICY visa_outcomes_select ON public.visa_outcomes
  FOR SELECT TO authenticated USING (true);

CREATE POLICY agents_select ON public.agents
  FOR SELECT TO authenticated USING (is_active = true);

-- ---- Users ----
CREATE POLICY users_select_own ON public.users
  FOR SELECT TO authenticated USING (id = auth.uid());

CREATE POLICY users_update_own ON public.users
  FOR UPDATE TO authenticated USING (id = auth.uid());

-- ---- User profiles ----
CREATE POLICY profiles_select_own ON public.user_profiles
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY profiles_insert_own ON public.user_profiles
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

CREATE POLICY profiles_update_own ON public.user_profiles
  FOR UPDATE TO authenticated USING (user_id = auth.uid());

-- ---- Subscriptions ----
CREATE POLICY subs_select_own ON public.subscriptions
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- ---- Credit transactions ----
CREATE POLICY credits_select_own ON public.credit_transactions
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- ---- Disclaimer events ----
CREATE POLICY disclaimer_select_own ON public.disclaimer_events
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- ---- Conversations ----
CREATE POLICY conv_select_own ON public.conversations
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- ---- Messages: EXISTS for performance over IN subquery at scale ----
CREATE POLICY messages_select_own ON public.messages
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE c.id = messages.conversation_id
        AND c.user_id = auth.uid()
    )
  );

-- ---- Conversation summaries ----
CREATE POLICY summaries_select_own ON public.conversation_summaries
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE c.id = conversation_summaries.conversation_id
        AND c.user_id = auth.uid()
    )
  );

-- ---- Pathway results ----
CREATE POLICY pathway_select_own ON public.pathway_results
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- ---- Points results ----
CREATE POLICY points_select_own ON public.points_results
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- ---- Feedback: INSERT validates conversation ownership ----
CREATE POLICY feedback_select_own ON public.feedback
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY feedback_insert_own ON public.feedback
  FOR INSERT TO authenticated WITH CHECK (
    user_id = auth.uid()
    AND (
      conversation_id IS NULL
      OR EXISTS (
        SELECT 1 FROM public.conversations c
        WHERE c.id = feedback.conversation_id
          AND c.user_id = auth.uid()
      )
    )
  );

-- ---- MARA referral events ----
CREATE POLICY mara_select_own ON public.mara_referral_events
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE c.id = mara_referral_events.conversation_id
        AND c.user_id = auth.uid()
    )
  );

-- ---- Document checklists ----
CREATE POLICY checklists_select_own ON public.document_checklists
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY checklists_insert_own ON public.document_checklists
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

CREATE POLICY checklists_update_own ON public.document_checklists
  FOR UPDATE TO authenticated USING (user_id = auth.uid());

-- ---- Checklist items ----
CREATE POLICY checklist_items_all ON public.checklist_items
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.document_checklists dc
      WHERE dc.id = checklist_items.checklist_id
        AND dc.user_id = auth.uid()
    )
  );

-- ---- EOI ----
CREATE POLICY eoi_snapshots_own ON public.eoi_snapshots
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY eoi_comparisons_own ON public.eoi_comparisons
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- ---- Alerts ----
CREATE POLICY alert_subs_own ON public.alert_subscriptions
  FOR ALL TO authenticated USING (user_id = auth.uid());

CREATE POLICY user_alerts_select ON public.user_alerts
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY user_alerts_update ON public.user_alerts
  FOR UPDATE TO authenticated USING (user_id = auth.uid());

-- ---- Documents ----
CREATE POLICY documents_own ON public.documents
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- ---- Family groups + members ----
CREATE POLICY family_groups_own ON public.family_groups
  FOR ALL TO authenticated USING (owner_id = auth.uid());

CREATE POLICY family_members_own ON public.family_members
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.family_groups fg
      WHERE fg.id = family_members.family_group_id
        AND fg.owner_id = auth.uid()
    )
  );

-- ---- Device tokens ----
CREATE POLICY device_tokens_own ON public.device_tokens
  FOR ALL TO authenticated USING (user_id = auth.uid());

-- ---- Data deletion requests ----
CREATE POLICY deletion_requests_insert ON public.data_deletion_requests
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

CREATE POLICY deletion_requests_select ON public.data_deletion_requests
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- ---- Waitlist: anon insert only ----
CREATE POLICY waitlist_insert_anon ON public.waitlist
  FOR INSERT TO anon WITH CHECK (true);

-- =============================================================================
-- 26. HELPER FUNCTIONS
-- All SECURITY DEFINER functions use SET search_path = public.
-- =============================================================================

-- 26.1  new_user_setup — fires on auth.users INSERT
CREATE OR REPLACE FUNCTION public.new_user_setup()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  INSERT INTO public.users (id, email) VALUES (NEW.id, NEW.email);
  INSERT INTO public.user_profiles (user_id) VALUES (NEW.id);
  INSERT INTO public.subscriptions (user_id, plan, credits_remaining)
    VALUES (NEW.id, 'free', 3);
  INSERT INTO public.credit_transactions
    (user_id, event_type, amount, balance_after, note)
  VALUES
    (NEW.id, 'grant', 3, 3, 'Signup grant — 3 free questions');
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_new_user_setup
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.new_user_setup();

-- 26.2  consume_credit — atomic deduction with row lock
CREATE OR REPLACE FUNCTION public.consume_credit(
  p_user_id         uuid,
  p_conversation_id uuid DEFAULT NULL
)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_plan          plan_type;
  v_credits       integer;
  v_balance_after integer;
BEGIN
  SELECT plan, credits_remaining INTO v_plan, v_credits
  FROM public.subscriptions
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_plan = 'pro' THEN RETURN -1; END IF;

  IF v_credits <= 0 THEN
    RAISE EXCEPTION 'CREDITS_EXHAUSTED: user % has 0 credits remaining.', p_user_id;
  END IF;

  v_balance_after := v_credits - 1;

  UPDATE public.subscriptions
  SET credits_remaining = v_balance_after
  WHERE user_id = p_user_id;

  INSERT INTO public.credit_transactions
    (user_id, event_type, amount, balance_after, conversation_id)
  VALUES
    (p_user_id, 'use', -1, v_balance_after, p_conversation_id);

  RETURN v_balance_after;
END;
$$;

-- 26.3  upgrade_to_pro — called by Stripe webhook handler
CREATE OR REPLACE FUNCTION public.upgrade_to_pro(
  p_user_id            uuid,
  p_stripe_customer_id text,
  p_stripe_sub_id      text,
  p_period_start       timestamptz DEFAULT now(),
  p_period_end         timestamptz DEFAULT now() + interval '1 month'
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  UPDATE public.subscriptions
  SET plan                   = 'pro',
      status                 = 'active',
      stripe_customer_id     = p_stripe_customer_id,
      stripe_subscription_id = p_stripe_sub_id,
      current_period_start   = p_period_start,
      current_period_end     = p_period_end,
      credits_remaining      = 0
  WHERE user_id = p_user_id;
END;
$$;

-- 26.4  purge_free_session — called by API on free-tier session end
CREATE OR REPLACE FUNCTION public.purge_free_session(p_session_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  UPDATE public.conversations
  SET ended_at = now()
  WHERE session_id = p_session_id AND ended_at IS NULL;

  UPDATE public.pathway_results SET session_id = NULL
  WHERE session_id = p_session_id;

  UPDATE public.points_results SET session_id = NULL
  WHERE session_id = p_session_id;
END;
$$;

-- 26.5  purge_user_pii — Privacy Act 1988 hard-delete
CREATE OR REPLACE FUNCTION public.purge_user_pii(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_email text;
BEGIN
  SELECT email INTO v_email FROM public.users WHERE id = p_user_id;

  UPDATE public.conversations
  SET user_profile_snapshot = NULL,
      tier_snapshot          = NULL
  WHERE user_id = p_user_id;

  UPDATE public.pathway_results
  SET input_profile = '{}'::jsonb
  WHERE user_id = p_user_id;

  UPDATE public.points_results
  SET input_data = '{}'::jsonb
  WHERE user_id = p_user_id;

  UPDATE public.family_members
  SET date_of_birth = NULL,
      nationality   = NULL
  WHERE family_group_id IN (
    SELECT id FROM public.family_groups WHERE owner_id = p_user_id
  );

  UPDATE public.disclaimer_events
  SET ip_hash    = NULL,
      session_id = NULL
  WHERE user_id = p_user_id;

  UPDATE public.user_profiles
  SET nationality        = NULL,
      visa_expiry        = NULL,
      occupation_title   = NULL,
      anzsco_code        = NULL,
      years_in_australia = NULL
  WHERE user_id = p_user_id;

  UPDATE public.users
  SET purged_at = now(),
      email     = 'purged-' || encode(extensions.digest(v_email, 'sha256'), 'hex') || '@deleted'
  WHERE id = p_user_id;

END;
$$;

COMMENT ON FUNCTION public.purge_user_pii IS
  'Privacy Act 1988 hard-delete. Wipes all PII across tables for the given user.
   disclaimer_events: ip_hash and session_id wiped; timestamps and disclaimer_version
   retained as anonymised MARA compliance evidence.
   Call ONLY after:
     1. data_deletion_requests.status = ''completed''
     2. 30-day processing window has elapsed
     3. Manual review confirms no legal hold applies.
   This function is irreversible.';

-- 26.6  get_active_prompt — used by API to build system prompt
CREATE OR REPLACE FUNCTION public.get_active_prompt(p_layer prompt_layer)
RETURNS TABLE (id uuid, version text, content text, content_hash text)
LANGUAGE sql STABLE
SET search_path = public AS $$
  SELECT id, version, content, content_hash
  FROM public.prompts
  WHERE layer = p_layer AND active = true
  LIMIT 1;
$$;

-- 26.7  flag_mara_cta_clicked — called by UI on CTA click
CREATE OR REPLACE FUNCTION public.flag_mara_cta_clicked(p_event_id uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER
SET search_path = public AS $$
  UPDATE public.mara_referral_events
  SET cta_clicked = true, clicked_at = now()
  WHERE id = p_event_id;
$$;

-- =============================================================================
-- 27. VIEWS
-- =============================================================================

CREATE VIEW public.v_moderation_pending AS
  SELECT mq.id, mq.conversation_id, mq.message_index, mq.flag_type,
         mq.triggered_keyword_codes, mq.content_excerpt, mq.flagged_at,
         c.user_id, s.plan AS user_plan
  FROM public.moderation_queue mq
  LEFT JOIN public.conversations c ON mq.conversation_id = c.id
  LEFT JOIN public.subscriptions s ON c.user_id = s.user_id
  WHERE mq.review_status = 'pending'
  ORDER BY mq.flagged_at ASC;

CREATE VIEW public.v_mara_funnel AS
  SELECT trigger_type,
    COUNT(*) AS total_shown,
    SUM(CASE WHEN cta_clicked THEN 1 ELSE 0 END) AS total_clicked,
    ROUND(
      100.0 * SUM(CASE WHEN cta_clicked THEN 1 ELSE 0 END)
      / NULLIF(COUNT(*), 0), 1
    ) AS click_rate_pct
  FROM public.mara_referral_events
  GROUP BY trigger_type
  ORDER BY total_shown DESC;

CREATE VIEW public.v_waitlist_pipeline AS
  SELECT email, referral_code, referred_by, referral_count,
         instagram_reel_id, utm_campaign, utm_source,
         joined_at, invited_at, converted_at,
         (converted_at IS NOT NULL) AS converted
  FROM public.waitlist
  ORDER BY joined_at DESC;

CREATE VIEW public.v_compliance_health AS
  SELECT review_month, reviewer_name,
         processing_times_updated, fees_updated, skillselect_cutoffs_checked,
         occupation_lists_checked, sentry_pii_logs_reviewed,
         moderation_queue_reviewed, policy_announcements_checked,
         model_behaviour_issues_reviewed, disclaimer_events_reviewed,
         new_knowledge_block_version, completed_at,
         (completed_at IS NULL) AS overdue
  FROM public.monthly_reviews
  ORDER BY review_month DESC;

CREATE VIEW public.v_points_distribution AS
  SELECT total_points, COUNT(*) AS result_count,
         MIN(created_at) AS first_seen, MAX(created_at) AS last_seen
  FROM public.points_results
  GROUP BY total_points
  ORDER BY total_points DESC;

CREATE VIEW public.v_disclaimer_acceptance AS
  SELECT disclaimer_version,
    COUNT(*) FILTER (WHERE event_type = 'shown')    AS shown_count,
    COUNT(*) FILTER (WHERE event_type = 'accepted') AS accepted_count,
    COUNT(*) FILTER (WHERE event_type = 'dismissed') AS dismissed_count,
    ROUND(
      100.0 * COUNT(*) FILTER (WHERE event_type = 'accepted')
      / NULLIF(COUNT(*) FILTER (WHERE event_type = 'shown'), 0), 1
    ) AS acceptance_rate_pct
  FROM public.disclaimer_events
  GROUP BY disclaimer_version;

CREATE VIEW public.v_conversations_no_disclaimer AS
  SELECT id, user_id, session_id, created_at, turn_count
  FROM public.conversations
  WHERE disclaimer_accepted_at IS NULL
    AND turn_count > 0
  ORDER BY created_at DESC;

-- =============================================================================
-- 28. SEED DATA
-- =============================================================================

INSERT INTO public.disclaimer_versions
  (version, content, content_hash, active, approved_by)
VALUES (
  '1.0',
  '-- PLACEHOLDER: Insert full disclaimer text here before launch --',
  encode(
    extensions.digest('-- PLACEHOLDER: Insert full disclaimer text here before launch --', 'sha256'),
    'hex'
  ),
  false,
  NULL
);

INSERT INTO public.prompts
  (version, layer, content, change_summary, created_by, compliance_approved, active)
VALUES
  ('2.0', 'core',      '-- PLACEHOLDER: Doc 1 --', 'Initial seed', 'engineering', false, false),
  ('2.0', 'knowledge', '-- PLACEHOLDER: Doc 2 --', 'Initial seed', 'engineering', false, false),
  ('2.0', 'pathway',   '-- PLACEHOLDER: Doc 3 --', 'Initial seed', 'engineering', false, false),
  ('2.0', 'points',    '-- PLACEHOLDER: Doc 4 --', 'Initial seed', 'engineering', false, false);

COMMIT;
