import { useCallback, useEffect, useState } from 'react'
import { useCanWrite } from '../hooks/useAuth'
import { api, calls } from '../lib/api'
import { syncDetail, syncKind } from '../lib/sync'
import type {
  ClusterNode, FeatureName, FeatureState, Features, HealthSettings, HealthSettingsState,
  NodeSetupState,
} from '../lib/types'
import { LoggingSettings } from './LoggingSettings'
import { ShieldIcon } from './Icons'

type Notify = (kind: 'success' | 'error' | 'info', title: string, detail?: string) => void

interface Props {
  nodes: ClusterNode[]
  setup: NodeSetupState | null
  onConfigure: () => void
  onNotify: Notify
  /** A feature changed: the menu reads the flags from the status poll. */
  onChanged: () => void
}

/**
 * Every setting in one place. Health, logging and the experimental features
 * are the cluster's, saved here and pushed to every member like a template;
 * how this node is reached is its own, which only it can say and which
 * changes by restarting it -- so that one is shown, and changed through
 * Configure node or `waterpump configure`.
 */
export function SettingsView({ nodes, setup, onConfigure, onNotify, onChanged }: Props) {
  const canWrite = useCanWrite()
  return (
    <>
      <div className="section-head">
        <h2>Settings</h2>
        <span className="faint" style={{ fontSize: 12.5 }}>
          {nodes.length > 1 ? 'shared by every member of the cluster, then this node’s own'
            : 'for this server, and for every node that joins it later'}
        </span>
      </div>
      <HealthCard canWrite={canWrite} onNotify={onNotify} />
      <LoggingSettings nodes={nodes} canWrite={canWrite} onNotify={onNotify} />
      <ThisNodeCard setup={setup} canWrite={canWrite} onConfigure={onConfigure} />
      {/* Last: switching these on is for someone who already knows the rest. */}
      <FeaturesCard canWrite={canWrite} onNotify={onNotify} onChanged={onChanged} />
    </>
  )
}

const FEATURES: { name: FeatureName; label: string; about: string }[] = [
  { name: 'stacks', label: 'Stacks',
    about: 'Templates launched in stages, each handed the addresses and values of the ones '
      + 'before, with health gates, scripts and load-test swarms, and operated as one '
      + 'deployment. Adds the Stacks tab.' },
  { name: 'fabrics', label: 'Fabrics',
    about: 'A routed network spanning every node, each with its own /24, so instances on '
      + 'different hosts reach each other directly. Needs the fabric helper’s sudo rules '
      + 'on every node. Adds Fabrics to the Network tab.' },
]

function FeaturesCard({ canWrite, onNotify, onChanged }: {
  canWrite: boolean
  onNotify: Notify
  onChanged: () => void
}) {
  const [state, setState] = useState<FeatureState | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback((signal?: AbortSignal) => {
    api.features(signal).then((next) => { setState(next); setError(null) })
      .catch((cause) => {
        if ((cause as Error).name !== 'AbortError') setError((cause as Error).message)
      })
  }, [])
  useEffect(() => {
    const controller = new AbortController()
    load(controller.signal)
    return () => controller.abort()
  }, [load])

  async function toggle(name: FeatureName, on: boolean) {
    if (!state) return
    const next: Features = { ...state.settings, [name]: on }
    setBusy(true)
    try {
      const saved = await api.saveFeatures(next)
      onNotify(syncKind(saved.synced), `${name === 'stacks' ? 'Stacks' : 'Fabrics'} switched ${on ? 'on' : 'off'}`,
        syncDetail(saved.synced) ?? 'Applied on this node.')
      onChanged()
    } catch (cause) {
      onNotify('error', 'Could not change the feature', (cause as Error).message)
    } finally {
      load()
      setBusy(false)
    }
  }

  return (
    <section className="card access-card">
      <header className="access-head">
        <h3>Experimental features</h3>
        <span className="faint">
          Off on a new install: they suit someone who already knows the rest of waterpump.
        </span>
      </header>
      {!state ? (
        <div className="access-inset">
          {error ? <span className="field-error">{error}</span>
            : <div className="loading-wrap"><span className="spinner" /> Reading settings…</div>}
        </div>
      ) : (
        <div className="logging-body">
          {FEATURES.map((feature) => {
            const on = state.settings[feature.name]
            const used = state.in_use[feature.name]
            return (
              <div className="field" key={feature.name}>
                <label className="check" style={{ fontWeight: 550 }}>
                  <input type="checkbox" checked={on}
                    disabled={!canWrite || busy || (on && used.length > 0)}
                    title={on && used.length ? 'In use, so it stays on' : calls.saveFeatures(
                      { ...state.settings, [feature.name]: !on }).path}
                    onChange={(e) => toggle(feature.name, e.target.checked)} />
                  {feature.label}
                  <span className="badge badge-warn">experimental</span>
                </label>
                <span className="hint">{feature.about}</span>
                {used.length > 0 && (
                  <span className="hint">
                    In use ({used.join(', ')}), so it cannot be switched off until
                    {used.length === 1 ? ' that is' : ' those are'} deleted.
                  </span>
                )}
              </div>
            )
          })}
        </div>
      )}
    </section>
  )
}

// What each threshold means, in the order the form asks them.
const HEALTH_FIELDS: { key: Exclude<keyof HealthSettings, 'enabled'>; label: string;
  unit: string; hint: string }[] = [
  { key: 'interval_seconds', label: 'Check every', unit: 'seconds',
    hint: 'How often each running instance is probed. At least 15.' },
  { key: 'cpu_percent', label: 'Degraded above CPU', unit: '%',
    hint: 'Of the instance’s CPUs, over the interval.' },
  { key: 'memory_percent', label: 'Degraded above memory', unit: '%',
    hint: 'Of its memory limit; an instance with no limit is not judged on memory.' },
  { key: 'load_average', label: 'Degraded above load', unit: '',
    hint: 'One-minute load average: runnable tasks, not scaled by CPUs.' },
  { key: 'probe_timeout_seconds', label: 'Probe timeout', unit: 'seconds',
    hint: 'How long to wait for an instance to answer.' },
  { key: 'failures_before_unhealthy', label: 'Unhealthy after', unit: 'missed probes',
    hint: 'Missed answers in a row before it counts.' },
  { key: 'start_grace_seconds', label: 'Start grace', unit: 'seconds',
    hint: 'After an instance starts, before any of this applies.' },
]

const SOURCE_TEXT: Record<HealthSettingsState['source'], string> = {
  cluster: 'The cluster’s settings, shared by every member.',
  node: 'This node’s own settings file, from before health checks were a cluster '
    + 'setting. Saving here replaces it for the whole cluster.',
  default: 'The defaults: nothing has been saved yet.',
}

function HealthCard({ canWrite, onNotify }: { canWrite: boolean; onNotify: Notify }) {
  const [state, setState] = useState<HealthSettingsState | null>(null)
  const [draft, setDraft] = useState<HealthSettings | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback((signal?: AbortSignal) => {
    api.healthSettings(signal).then((next) => {
      setState(next)
      setDraft(next.settings)
      setError(null)
    }).catch((cause) => {
      if ((cause as Error).name !== 'AbortError') setError((cause as Error).message)
    })
  }, [])
  useEffect(() => {
    const controller = new AbortController()
    load(controller.signal)
    return () => controller.abort()
  }, [load])

  if (!state || !draft) {
    return (
      <section className="card access-card">
        <header className="access-head"><h3>Health checks</h3></header>
        <div className="access-inset">
          {error ? <span className="field-error">{error}</span>
            : <div className="loading-wrap"><span className="spinner" /> Reading settings…</div>}
        </div>
      </section>
    )
  }

  const dirty = JSON.stringify(draft) !== JSON.stringify(state.settings)
  const valid = HEALTH_FIELDS.every((f) => Number.isFinite(draft[f.key]) && draft[f.key] >= 0)
    && draft.interval_seconds >= 15

  async function save() {
    if (!draft) return
    setBusy(true)
    try {
      const saved = await api.saveHealthSettings(draft)
      onNotify(syncKind(saved.synced), 'Health settings saved',
        syncDetail(saved.synced) ?? 'In force on this node from its next round.')
      load()
    } catch (cause) {
      onNotify('error', 'Could not save the health settings', (cause as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="card access-card">
      <header className="access-head">
        <h3>Health checks</h3>
        <span className="faint">
          How every node judges its running instances. Takes effect without a restart.
        </span>
        <div className="row-actions access-head-end">
          {dirty && (
            <button className="btn btn-sm" disabled={busy} onClick={() => setDraft(state.settings)}>
              Discard
            </button>
          )}
          <button className="btn btn-sm btn-primary" disabled={busy || !canWrite || !dirty || !valid}
            title={calls.saveHealthSettings(draft).path} onClick={save}>
            {busy && <span className="spinner" />}Save for the cluster
          </button>
        </div>
      </header>
      <div className="logging-body">
        <span className="hint">{SOURCE_TEXT[state.source]}</span>
        {state.warning && <span className="field-error">{state.warning}</span>}
        <label className="check" style={{ fontWeight: 550 }}>
          <input type="checkbox" checked={draft.enabled} disabled={!canWrite}
            onChange={(e) => setDraft({ ...draft, enabled: e.target.checked })} />
          Run health checks
        </label>
        {draft.enabled && (
          <div className="settings-grid">
            {HEALTH_FIELDS.map((field) => (
              <div className="field" key={field.key}>
                <label htmlFor={`health-${field.key}`}>
                  {field.label}{field.unit && <span className="faint"> ({field.unit})</span>}
                </label>
                <input id={`health-${field.key}`} className="input" type="number" min={0}
                  step="any" value={draft[field.key]} disabled={!canWrite}
                  onChange={(e) => setDraft({ ...draft, [field.key]: Number(e.target.value) })} />
                <span className="hint">{field.hint}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </section>
  )
}

function ThisNodeCard({ setup, canWrite, onConfigure }: {
  setup: NodeSetupState | null
  canWrite: boolean
  onConfigure: () => void
}) {
  if (!setup) return null
  const rows: [string, string, string][] = [
    ['Listening on', `${setup.tls ? 'https' : 'http'}://${setup.host}:${setup.port}`
      + (setup.public ? '' : ' (this host only)'), 'listen'],
    ['Certificate', setup.certificate
      ? (setup.certificate.error || setup.certificate.fingerprint_pretty) : 'none: plain HTTP', 'tls'],
    ['Logins', setup.auth ? setup.auth_methods.join(', ') || 'on' : 'off: whoever reaches the port is admin',
      'auth'],
  ]
  return (
    <section className="card access-card">
      <header className="access-head">
        <h3>This node</h3>
        <span className="faint">
          How it is reached. Only this node can say, so it is not shared; changing it restarts
          waterpump here.
        </span>
        {canWrite && (
          <div className="row-actions access-head-end">
            <button className="btn btn-sm" onClick={onConfigure} disabled={!!setup.blocked}
              title={setup.blocked || undefined}>
              <ShieldIcon size={14} /> Configure node
            </button>
          </div>
        )}
      </header>
      <div className="table-scroll">
        <table className="ctable">
          <tbody>
            {rows.map(([label, value, section]) => (
              <tr key={label}>
                <td style={{ width: 160 }}><strong>{label}</strong></td>
                <td className="mono">{value}</td>
                <td className="faint">
                  <span className="mono">waterpump configure {section}</span>
                  {setup.pinned.length > 0 && section === 'listen'
                    && <> · overridden by {setup.pinned.join(', ')}</>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
