import { useCallback, useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { api } from '../lib/api'
import { keyOf } from '../lib/instance'
import type {
  ClusterContainers, ClusterNode, Features, HealthRecord, HealthStatus, InstanceTemplate, Stack,
  StackRun, Task, TaskRun, TaskRunStatus, TemplateRun,
} from '../lib/types'
import { ResourcesView } from './ResourcesView'

// Every listing here asks each member, like the Cluster tab, so it keeps that
// tab's slower pace rather than App's 3s one; runs come from App's poll.
const POLL_INTERVAL = 10000

type Instance = ClusterContainers['instances'][number]
type Destination = 'containers' | 'templates' | 'stacks' | 'tasks' | 'cluster'

interface Props {
  templateRuns: TemplateRun[]
  stackRuns: StackRun[]
  /** Experimental features in force: stacks are shown only while they are on. */
  features: Features | undefined
  onNavigate: (view: Destination) => void
}

interface Overview {
  cluster: ClusterContainers
  nodes: ClusterNode[]
  templates: InstanceTemplate[]
  stacks: Stack[]
  tasks: Task[]
  runs: TaskRun[]
}

const RUN_BADGE: Record<TaskRunStatus, string> = {
  running: 'badge-info', ok: 'badge-ok', failed: 'badge-danger', timed_out: 'badge-danger',
  cancelled: 'badge-dim', missed: 'badge-warn', vetoed: 'badge-warn', lost: 'badge-warn',
}
// What a task's latest run says about it; a run that never got going is not news.
const FAILED: TaskRunStatus[] = ['failed', 'timed_out', 'lost', 'missed']

// Worst first: a group of instances reads as its least healthy member.
const SEVERITY: HealthStatus[] = ['unhealthy', 'degraded', 'starting', 'unknown', 'paused', 'healthy']
const TONE: Record<HealthStatus, string> = {
  healthy: 'health-ok', degraded: 'health-warn', unhealthy: 'health-danger',
  starting: 'health-info', unknown: 'health-dim', paused: 'health-dim',
}

/**
 * The first screen: this node's state, and what the whole cluster is running
 * -- instances by template, and tasks with their latest runs (stacks too, when
 * that experimental feature is on). Each list points at the tab managing it.
 */
export function HomeView({ templateRuns, stackRuns, features, onNavigate }: Props) {
  const [data, setData] = useState<Overview | null>(null)
  const [error, setError] = useState<string | null>(null)

  const withStacks = features?.stacks ?? false
  const load = useCallback((signal?: AbortSignal) => {
    Promise.all([
      api.clusterContainers({ all: true }, signal),
      api.nodes(signal),
      api.templates(signal),
      withStacks ? api.stacks(signal) : Promise.resolve([] as Stack[]),
      api.tasks(signal),
      // Every member's runs, so "last run" is the task's, wherever it ran.
      api.taskRuns(undefined, signal).catch(() => ({ runs: [], errors: [] })),
    ]).then(([cluster, nodes, templates, stacks, tasks, runs]) => {
      setData({ cluster, nodes, templates, stacks, tasks, runs: runs.runs })
      setError(null)
    }).catch((cause) => {
      if ((cause as Error).name !== 'AbortError') setError((cause as Error).message)
    })
  }, [withStacks])

  useEffect(() => {
    const controller = new AbortController()
    load(controller.signal)
    const timer = window.setInterval(() => load(controller.signal), POLL_INTERVAL)
    return () => { controller.abort(); window.clearInterval(timer) }
  }, [load])

  const health: Record<string, HealthRecord> = {}
  for (const record of data?.cluster.health ?? []) health[keyOf(record)] = record
  const instances = data?.cluster.instances ?? []

  return (
    <>
      {error && (
        <div className="banner banner-error">
          <div className="banner-body"><p style={{ margin: 0 }}>{error}</p></div>
        </div>
      )}

      {!data ? (
        <div className="card">
          <div className="loading-wrap"><span className="spinner" /> Reading the cluster…</div>
        </div>
      ) : (
        <>
          <Tiles data={data} health={health} withStacks={withStacks} onNavigate={onNavigate} />

          {data.cluster.errors.length > 0 && (
            <div className="banner banner-warn">
              <div className="banner-body">
                <h3>{data.cluster.errors.length} node(s) did not answer</h3>
                <p style={{ margin: 0 }}>
                  What they run is missing below:{' '}
                  {data.cluster.errors.map((e) => `${e.node} (${e.error})`).join('; ')}
                </p>
              </div>
            </div>
          )}

          <div className="home-grid">
            <WorkloadCard
              title="Templates"
              empty="No templates saved yet."
              onOpen={() => onNavigate('templates')}
              rows={data.templates.map((template) => {
                const run = templateRuns.find(
                  (r) => r.template === template.name && r.finished_at === null)
                return {
                  kind: 'template' as const,
                  name: template.name,
                  description: template.description,
                  members: instances.filter((i) => i.template === template.name),
                  activity: run ? runLabel(run) : null,
                }
              })}
              health={health}
            />
            <TasksCard tasks={data.tasks} runs={data.runs} onOpen={() => onNavigate('tasks')} />
            {withStacks && <WorkloadCard
              title="Stacks"
              empty="No stacks saved yet."
              onOpen={() => onNavigate('stacks')}
              rows={data.stacks.map((stack) => {
                const run = stackRuns.find((r) => r.stack === stack.name && r.finished_at === null)
                return {
                  kind: 'stack' as const,
                  name: stack.name,
                  description: stack.description,
                  members: instances.filter((i) => i.stack === stack.name),
                  activity: run ? `${run.action === 'destroy' ? 'destroying' : `${run.action}ing`}${
                    run.cancelling ? ' (cancelling)' : ''}` : null,
                }
              })}
              health={health}
            />}
          </div>

          {data.nodes.length > 1 && (
            <NodesCard nodes={data.nodes} instances={instances} health={health}
              onOpen={() => onNavigate('cluster')} />
          )}
        </>
      )}

      <div className="section-head home-section">
        <h2>This node</h2>
        <span className="faint" style={{ fontSize: 12.5 }}>
          what instances here have claimed against what this host has
        </span>
      </div>
      <ResourcesView />
    </>
  )
}

function runLabel(run: TemplateRun) {
  const verb = { launch: 'launching', recreate: 'recreating', destroy: 'destroying',
    exec: 'running a command on' }[run.action]
  return `${verb} ${run.count}`
}

function Tiles({ data, health, withStacks, onNavigate }: {
  data: Overview
  health: Record<string, HealthRecord>
  withStacks: boolean
  onNavigate: (view: Destination) => void
}) {
  const instances = data.cluster.instances
  const running = instances.filter((i) => i.status === 'Running').length
  const reachable = data.nodes.filter((n) => n.self || n.state?.reachable).length
  const statuses = instances.map((i) => health[keyOf(i)]?.status).filter(Boolean)
  const troubled = statuses.filter((s) => s === 'unhealthy' || s === 'degraded').length
  const stacksUp = data.stacks.filter((s) =>
    instances.some((i) => i.stack === s.name && i.status === 'Running')).length
  const templatesUsed = data.templates.filter((t) =>
    instances.some((i) => i.template === t.name)).length
  const loose = instances.filter((i) => !i.template && !i.stack).length
  const latest = latestRuns(data.runs)
  const failing = data.tasks.filter((t) => FAILED.includes(latest.get(t.name)?.status as TaskRunStatus)).length

  return (
    <div className="home-tiles">
      <Tile label="Nodes" value={`${reachable}/${data.nodes.length}`}
        detail={reachable === data.nodes.length ? 'all answering' : `${data.nodes.length - reachable} not answering`}
        tone={reachable === data.nodes.length ? undefined : 'warn'}
        onClick={() => onNavigate('cluster')} />
      <Tile label="Containers" value={`${running}/${instances.length}`}
        detail={`running${loose ? ` · ${loose} made by hand` : ''}`}
        onClick={() => onNavigate('containers')} />
      <Tile label="Health" value={troubled ? String(troubled) : 'OK'}
        detail={troubled ? 'degraded or unhealthy' : `${statuses.length} checked`}
        tone={troubled ? 'danger' : 'ok'}
        onClick={() => onNavigate('containers')} />
      <Tile label="Tasks" value={failing ? String(failing) : String(data.tasks.length)}
        detail={failing ? 'last run failed' : data.tasks.length === 1 ? 'task' : 'tasks'}
        tone={failing ? 'danger' : undefined}
        onClick={() => onNavigate('tasks')} />
      {withStacks && (
        <Tile label="Stacks" value={`${stacksUp}/${data.stacks.length}`} detail="running"
          onClick={() => onNavigate('stacks')} />
      )}
      <Tile label="Templates" value={`${templatesUsed}/${data.templates.length}`} detail="in use"
        onClick={() => onNavigate('templates')} />
    </div>
  )
}

/** Each task's most recent run, by task name. */
function latestRuns(runs: TaskRun[]) {
  const latest = new Map<string, TaskRun>()
  for (const run of runs) {
    const seen = latest.get(run.task)
    if (!seen || run.started_at > seen.started_at) latest.set(run.task, run)
  }
  return latest
}

function TasksCard({ tasks, runs, onOpen }: {
  tasks: Task[]
  runs: TaskRun[]
  onOpen: () => void
}) {
  const latest = latestRuns(runs)
  const running = (name: string) => runs.some((r) => r.task === name && r.status === 'running')
  // Running and failing first: those are what someone opening Home came for.
  const rank = (task: Task) => (running(task.name) ? 0
    : FAILED.includes(latest.get(task.name)?.status as TaskRunStatus) ? 1 : 2)
  const sorted = [...tasks].sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name))
  return (
    <section className="card home-card">
      <header className="home-card-head">
        <h3>Tasks</h3>
        <span className="faint">across the cluster</span>
        <button type="button" className="btn btn-ghost btn-sm" onClick={onOpen}>
          Manage
        </button>
      </header>
      {tasks.length === 0 ? (
        <div className="empty">
          <p>No tasks yet. A task runs a job in a throwaway instance, on a schedule or on
            demand.</p>
        </div>
      ) : (
        <ul className="home-list">
          {sorted.map((task) => {
            const last = latest.get(task.name)
            return (
              <li key={task.name} className="home-item">
                <div className="home-item-main">
                  <strong className="truncate">{task.name}</strong>
                  <span className="faint truncate">
                    {task.placement_problem ? task.placement_problem
                      : task.next_run && task.enabled
                        ? `next ${new Date(task.next_run * 1000).toLocaleString()}`
                        : task.schedule_text && !task.enabled ? 'schedule paused'
                          : 'run on demand'}
                  </span>
                </div>
                <div className="home-item-meta">
                  {running(task.name) && (
                    <span className="badge badge-info"><span className="spinner spinner-xs" />running</span>
                  )}
                  {last && !running(task.name) && (
                    <span className={`badge ${RUN_BADGE[last.status]}`}
                      title={`Last run on ${last.node}, ${new Date(last.started_at * 1000).toLocaleString()}`}>
                      {last.status.replace('_', ' ')}
                    </span>
                  )}
                  {!last && <span className="badge badge-dim">never run</span>}
                </div>
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}

function Tile({ label, value, detail, tone, onClick }: {
  label: string
  value: string
  detail: string
  tone?: 'ok' | 'warn' | 'danger'
  onClick: () => void
}) {
  return (
    <button type="button" className={`home-tile${tone ? ` home-tile-${tone}` : ''}`}
      onClick={onClick}>
      <span className="stat-label">{label}</span>
      <span className="home-tile-value">{value}</span>
      <span className="home-tile-detail">{detail}</span>
    </button>
  )
}

interface WorkloadRow {
  /** Which revision an instance is judged against for this row. */
  kind: 'template' | 'stack'
  name: string
  description: string
  members: Instance[]
  /** What a run is doing to it right now, if one is. */
  activity: string | null
}

function WorkloadCard({ title, empty, rows, health, onOpen }: {
  title: string
  empty: string
  rows: WorkloadRow[]
  health: Record<string, HealthRecord>
  onOpen: () => void
}) {
  // What is running, or being worked on, before what merely exists.
  const sorted = [...rows].sort((a, b) =>
    Number(!!b.activity) - Number(!!a.activity)
    || b.members.length - a.members.length
    || a.name.localeCompare(b.name))
  return (
    <section className="card home-card">
      <header className="home-card-head">
        <h3>{title}</h3>
        <span className="faint">across the cluster</span>
        <button type="button" className="btn btn-ghost btn-sm" onClick={onOpen}>
          Manage
        </button>
      </header>
      {rows.length === 0 ? (
        <div className="empty"><p>{empty}</p></div>
      ) : (
        <ul className="home-list">
          {sorted.map((row) => (
            <WorkloadItem key={row.name} row={row} health={health} />
          ))}
        </ul>
      )}
    </section>
  )
}

function WorkloadItem({ row, health }: { row: WorkloadRow; health: Record<string, HealthRecord> }) {
  const running = row.members.filter((m) => m.status === 'Running').length
  const stale = row.members.filter((m) => m.stale?.includes(row.kind)).length
  const nodes = [...new Set(row.members.map((m) => m.node))].sort()
  const worst = SEVERITY.find((s) => row.members.some((m) => health[keyOf(m)]?.status === s))
  const state = row.members.length === 0 ? { text: 'not running', badge: 'badge-dim' }
    : running === row.members.length ? { text: `${running} running`, badge: 'badge-ok' }
      : running === 0 ? { text: `${row.members.length} stopped`, badge: 'badge-dim' }
        : { text: `${running} of ${row.members.length} running`, badge: 'badge-warn' }
  return (
    <li className="home-item">
      <div className="home-item-main">
        <strong className="truncate">{row.name}</strong>
        {row.description && <span className="faint truncate">{row.description}</span>}
      </div>
      <div className="home-item-meta">
        {row.activity && (
          <span className="badge badge-info"><span className="spinner spinner-xs" />{row.activity}</span>
        )}
        {stale > 0 && (
          <span className="badge badge-warn"
            title={`Made from an older version of this ${row.kind}; ${
              row.kind === 'template' ? 'recreate them' : 'relaunch it'} to update`}>
            {stale} stale
          </span>
        )}
        {worst && worst !== 'healthy' && (
          <span className={`health-label ${TONE[worst]}`} title="The least healthy of its instances">
            <span className="health-dot" aria-hidden="true" />{worst}
          </span>
        )}
        <span className={`badge ${state.badge}`}>{state.text}</span>
      </div>
      {nodes.length > 0 && (
        <div className="home-item-nodes">
          {nodes.map((node) => {
            const here = row.members.filter((m) => m.node === node)
            return (
              <span key={node} className="badge badge-dim" title={here.map((m) => m.name).join(', ')}>
                {node} · {here.length}
              </span>
            )
          })}
        </div>
      )}
    </li>
  )
}

function NodesCard({ nodes, instances, health, onOpen }: {
  nodes: ClusterNode[]
  instances: Instance[]
  health: Record<string, HealthRecord>
  onOpen: () => void
}) {
  return (
    <section className="card home-card">
      <header className="home-card-head">
        <h3>Nodes</h3>
        <span className="faint">{nodes.length} in the cluster</span>
        <button type="button" className="btn btn-ghost btn-sm" onClick={onOpen}>Manage</button>
      </header>
      <div className="table-scroll">
        <table className="ctable">
          <thead>
            <tr>
              <th>Node</th><th>State</th><th className="optional">Daemon</th>
              <th className="num">Running</th><th className="num">Needs attention</th>
            </tr>
          </thead>
          <tbody>
            {[...nodes].sort((a, b) => Number(b.self) - Number(a.self) || a.name.localeCompare(b.name))
              .map((node) => {
                const here = instances.filter((i) => i.node === node.name)
                const troubled = here.filter((i) => {
                  const status = health[keyOf(i)]?.status
                  return status === 'unhealthy' || status === 'degraded'
                }).length
                const state: ReactNode = node.maintenance
                  ? <span className="badge badge-warn" title={node.maintenance.reason}>
                      <span className="dot" />maintenance
                    </span>
                  : node.state === null ? <span className="faint">not asked</span>
                  : node.state.reachable
                    ? <span className="badge badge-ok"><span className="dot" />ok</span>
                    : <span className="badge badge-danger" title={node.state.error ?? ''}>
                        <span className="dot" />unreachable
                      </span>
                return (
                  <tr key={node.name}>
                    <td>
                      <strong>{node.name}</strong>
                      {node.self && <span className="faint"> (this node)</span>}
                      {node.groups.length > 0 && (
                        <div className="res-sub">{node.groups.join(', ')}</div>
                      )}
                    </td>
                    <td>{state}</td>
                    <td className="optional dim">
                      {node.state?.product ? `${node.state.product} ${node.state.server_version ?? ''}` : '—'}
                    </td>
                    <td className="num">
                      {here.filter((i) => i.status === 'Running').length}
                      <span className="faint"> / {here.length}</span>
                    </td>
                    <td className="num">
                      {troubled ? <span className="health-danger">{troubled}</span>
                        : <span className="faint">—</span>}
                    </td>
                  </tr>
                )
              })}
          </tbody>
        </table>
      </div>
    </section>
  )
}

