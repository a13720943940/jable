// antd v5 静态方法（Modal.confirm/message/notification）在 React 19 下失效，官方要求加载此补丁
import '@ant-design/v5-patch-for-react-19'
import React, { useEffect, useMemo, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { createPortal } from 'react-dom'
import {
  App as AntApp, Alert, Badge, Button, Card, Cascader, Collapse, ConfigProvider, Descriptions, Divider, Drawer, Empty, Form,
  Image, Input, InputNumber, Layout, List, Menu, Modal, Pagination, Progress, Radio, Segmented,
  Popconfirm, Space, Select, Spin, Statistic, Switch, Table, Tabs, Tag, Typography, message
} from 'antd'
import { ApiOutlined, CheckCircleOutlined, CloseCircleOutlined, CloudDownloadOutlined, CloudServerOutlined, CloudUploadOutlined, CopyOutlined, DeleteOutlined, FolderOpenOutlined, ClearOutlined, FileTextOutlined, LeftOutlined, LinkOutlined, LoadingOutlined, LockOutlined, LogoutOutlined, PlayCircleOutlined, PlaySquareOutlined, PlusOutlined, QrcodeOutlined, ReloadOutlined, RightOutlined, SafetyOutlined, DatabaseOutlined, ScanOutlined, SearchOutlined, SettingOutlined, StopOutlined, SyncOutlined, ThunderboltOutlined, ToolOutlined, VideoCameraOutlined, WarningOutlined, FullscreenOutlined, FullscreenExitOutlined } from '@ant-design/icons'
import './styles.css'
import Hls from 'hls.js'

type Film = { detail_url: string; title: string; catalog: string; image_url: string; duration: string }
type MagnetLink = { name: string; url: string; size?: string; files?: string }
type FilmDetail = { detail_url: string; title: string; catalog: string; cover_url: string; samples: string[]; magnets: MagnetLink[] }
type CatalogSection = 'latest' | 'chinese'
type CatalogPage = { section?: CatalogSection; page: number; items: Film[]; page_size: number; has_next: boolean }
type DownloadTask = {
  id: string; title: string; catalog: string; state: string; phase: string; progress: number;
  speed: string; size: string; created_at: string; cover_url?: string; output_path?: string;
  task_type?: string; source_path?: string; scrape_step?: string; organize_step?: string;
  source_used?: string; metadata_found?: number; result_message?: string;
}
type CloudTask = { id: string; title: string; catalog: string; state: string; message: string; play_url: string; file_path?: string; created_at: string; detail_url: string; strm_id?: string; pickcode?: string; cover_url?: string }
type StrmItem = { id: string; catalog: string; title: string; file_path?: string; size?: number; created_at: string; poster_path?: string; strm_path?: string; pickcode?: string; cover_url?: string }
type HgEpisodeTask = { id: string; series_id: string; ep: number; episode_title: string; state: string; upload_state: string; progress: number; message: string; error: string; file_path: string; upload_path: string; created_at: string; updated_at: string; series_title: string; cover_url: string }
type Settings = {
  threads: number; proxy: string; cloud115_mode: 'bridge' | 'cookie'; cloud115_endpoint: string;
  cloud115_token: string; cloud115_cookie: string; jable_cookie: string; cloud115_token_configured?: boolean;
  cloud115_cookie_configured?: boolean; jable_cookie_configured?: boolean;
  local_scrape_enabled?: boolean; local_transfer_enabled?: boolean; local_transfer_path?: string;
  manual_scrape_enabled?: boolean; manual_transfer_enabled?: boolean; manual_transfer_path?: string;
  watch_enabled?: boolean; watch_dir?: string; watch_interval?: number;
  cloud_transfer_enabled?: boolean; cloud_transfer_path?: string; cloud_transfer_cid?: string; cloud_poll_interval?: number; cloud_ad_min_mb?: number;
  auto_strm_enabled?: boolean; service_base_url?: string; strm_root_dir?: string;
  cloud115_play_mode?: 'proxy' | 'redirect';
  cloud115_signin_enabled?: boolean; cloud115_signin_cron?: string; cloud115_signin_retry_count?: number; cloud115_signin_retry_interval?: number;
  auto_offline_enabled?: boolean; auto_offline_browse?: boolean; auto_offline_schedule?: boolean;
  auto_offline_interval?: number; auto_offline_pages?: number; auto_offline_whitelist?: string;
  auto_offline_min_duration?: number; auto_offline_min_size?: number; auto_offline_daily_limit?: number;
  media_root?: string; data_root?: string;
  organize_enabled?: boolean; allow_duplicate?: boolean;
  failure_route_enabled?: boolean; failure_path?: string;
  privacy_mode?: boolean;
  site_password_configured?: boolean;
  hg_upload_strategy?: 'completed' | 'episode' | 'never'; hg_upload_enabled?: boolean; hg_delete_after_upload?: boolean; hg_target_cid?: string; hg_target_path?: string; hg_check_interval?: number; hg_use_proxy?: boolean; hg_site_mirrors?: string; hg_episode_concurrency?: number; hg_follow_enabled?: boolean; hg_follow_pages?: number;
}
interface HeroStats { cloud_active: number; cloud_done: number; strm_count: number; auto_today: number }
type Capture = { detail_url: string; title: string; catalog: string; media_url: string }
type QRInfo = { uid: string; qrcode: string; image: string }
type HgSeries = {
  id: string; title: string; origin: string; detail_url: string; cover_url: string; description: string;
  follow_enabled: number; completed: number; total_episodes: number; downloaded_episodes: number; uploaded_episodes: number;
  latest_episode: number; last_checked_at: string; created_at: string;
  failed_count?: number; active_episodes?: { ep: number; state: string; progress: number; message: string }[];
}
type HgEpisode = {
  id: string; series_id: string; ep: number; title: string; play_url: string; stream_url: string;
  state: string; upload_state: string; progress: number; file_path: string; upload_path: string;
  upload_file_id: string; message: string; error: string; created_at: string; updated_at: string;
}
type HgCatalogItem = { id: string; title: string; cover_url: string; remark: string; detail_url: string }
type HgCatalogReply = { items: HgCatalogItem[]; tabs: { name: string; id: string }[]; page: number; query: string; source_url: string }
type SigninLog = { id: string; created_at: string; state: string; message: string; reward?: string }
type SigninStatus = { ok: boolean; enabled: boolean; cron: string; retry_count?: number; retry_interval?: number; logs: SigninLog[]; message?: string }

// 后端在未授权时对 index.html 注入 window.__UNLICENSED__；api 层短路，避免锁页期间重复请求/报错
let __unlicensed = (window as unknown as { __UNLICENSED__?: boolean }).__UNLICENSED__ === true
let __accessLocked = (window as unknown as { __ACCESS_LOCKED__?: boolean }).__ACCESS_LOCKED__ === true

function syncH5Class() {
  const ua = navigator.userAgent || ''
  const isPhone = /iPhone|iPod|Android.*Mobile|Windows Phone|Mobile/i.test(ua)
  const narrowScreen = Math.min(window.screen.width || 9999, window.innerWidth || 9999) <= 820
  document.body.classList.toggle('is-h5', isPhone || narrowScreen)
}
syncH5Class()

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  if (__accessLocked && !path.startsWith('/api/access')) throw new Error('请输入访问密码')
  if (__unlicensed && !path.startsWith('/api/license') && !path.startsWith('/api/access')) throw new Error('未授权或授权已过期，请输入授权码')
  const response = await fetch(path, init)
  const data = await response.json().catch(() => ({}))
  if (response.status === 401 && data.error === 'access_locked') __accessLocked = true
  if (response.status === 403 && data.error === 'unlicensed') __unlicensed = true
  if (!response.ok) throw new Error(data.message || data.error || '请求失败')
  return data as T
}

// localStorage 缓存:F5 刷新或重新进入页面时先用上次数据渲染，再后台静默刷新
const CACHE_PREFIX = 'nassav:'
function loadCache<T>(key: string): T | null {
  try {
    const raw = localStorage.getItem(CACHE_PREFIX + key)
    if (!raw) return null
    const parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== 'object' || typeof parsed.expire !== 'number') return null
    if (Date.now() > parsed.expire) { localStorage.removeItem(CACHE_PREFIX + key); return null }
    return parsed.data as T
  } catch { return null }
}
function saveCache<T>(key: string, data: T, ttlMs = 1000 * 60 * 60): void {
  try { localStorage.setItem(CACHE_PREFIX + key, JSON.stringify({ data, expire: Date.now() + ttlMs })) } catch { /* quota */ }
}
// 启动时只读一次的缓存键
const CACHE_KEYS = {
  films: 'films', catalogPage: 'catalogPage', hasNextPage: 'hasNextPage',
  settings: 'settings', downloads: 'downloads', cloudTasks: 'cloudTasks'
}

const filmCacheKey = (section: CatalogSection, key: 'films' | 'catalogPage' | 'hasNextPage') => `${key}:${section}`

type LicenseInfo = { device_id: string; activated: boolean; expires_at: number; expired?: boolean; message?: string }
type AccessInfo = { configured: boolean; authenticated: boolean; message?: string }
type AppLog = {
  id: string; created_at: string; level: 'debug' | 'info' | 'success' | 'warning' | 'error'
  module: string; action: string; target: string; message: string; detail: string; task_id: string
}
type LogStats = {
  total: number
  today: Record<string, number>
  modules: { module: string; n: number }[]
  last_error?: { created_at: string; module: string; action: string; message: string; target: string } | null
}

function formatExpiry(ts: number): string {
  if (!ts) return '永久有效'
  const d = new Date(ts * 1000)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function LicenseManager({ onActivated }: { onActivated?: () => void }) {
  const [info, setInfo] = useState<LicenseInfo | null>(null)
  const [code, setCode] = useState('')
  const [loading, setLoading] = useState(false)
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null)
  const fetchInfo = () => { setInfo(null); api<LicenseInfo>('/api/license').then(setInfo).catch(() => {}) }
  useEffect(() => { api<LicenseInfo>('/api/license').then(setInfo).catch(() => {}) }, [])
  const expiredNow = !!info && info.expires_at > 0 && info.expires_at * 1000 < Date.now()
  const activate = async () => {
    if (!code.trim() || loading) return
    setLoading(true); setResult(null)
    try {
      const res = await api<LicenseInfo & { ok: boolean }>('/api/license/activate', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ license_code: code }) })
      setInfo(res); setCode(''); setResult({ ok: true, text: res.message || '授权成功' })
      onActivated?.()
    } catch (e) { if (e instanceof Error) setResult({ ok: false, text: e.message }) }
    finally { setLoading(false) }
  }
  const deactivate = () => {
    Modal.confirm({
      title: '清除本机授权？',
      content: '清除后页面会立即重新加载，并回到授权验证页。',
      okText: '清除',
      okButtonProps: { danger: true },
      cancelText: '取消',
      async onOk() {
        await api<LicenseInfo & { ok: boolean }>('/api/license/deactivate', { method: 'POST' })
        __unlicensed = true
        window.location.reload()
      }
    })
  }
  return <div style={{ maxWidth: 560 }}>
    <Typography.Paragraph type="secondary">本服务采用「设备码 + 有效期」离线授权。将设备码发送给管理员换取授权码，粘贴后点激活；激活或续期立即生效。</Typography.Paragraph>
    <Space.Compact style={{ width: '100%', marginBottom: 16 }}>
      <Input value={info?.device_id || ''} readOnly placeholder="设备码加载中..." />
      <Button icon={<CopyOutlined />} onClick={() => { if (info?.device_id) { navigator.clipboard?.writeText(info.device_id); message.success('设备码已复制') } }}>复制</Button>
    </Space.Compact>
    <div style={{ marginBottom: 16 }}>
      <Typography.Text type="secondary">授权状态：</Typography.Text>
      {!info ? <Tag>检测中</Tag>
        : info.activated && !expiredNow ? <Tag color="green">已授权 · {formatExpiry(info.expires_at)}</Tag>
        : <Tag color="red">{info.expired || expiredNow ? '授权已过期' : '未授权'}</Tag>}
    </div>
    <Input.TextArea value={code} onChange={e => setCode(e.target.value)} rows={3} placeholder="粘贴授权码（可保留 - 分隔符，自动清理）" />
    <Space style={{ marginTop: 12 }}>
      <Button type="primary" loading={loading} disabled={!code.trim()} onClick={activate}>激活授权</Button>
      <Button icon={<ReloadOutlined />} onClick={fetchInfo}>刷新状态</Button>
      {info?.activated && !expiredNow && <Button danger icon={<DeleteOutlined />} onClick={deactivate}>清除授权</Button>}
    </Space>
    {result && <Alert type={result.ok ? 'success' : 'error'} showIcon message={result.text} style={{ marginTop: 12 }} />}
  </div>
}

function LicenseGate({ onActivated }: { onActivated: () => void }) {
  return <div className="license-gate"><Card className="license-gate-card">
    <Typography.Title level={3} style={{ textAlign: 'center', marginTop: 0 }}><SafetyOutlined /> 授权验证</Typography.Title>
    <LicenseManager onActivated={onActivated} />
  </Card></div>
}

function AccessGate({ onUnlocked }: { onUnlocked: () => void }) {
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const login = async () => {
    if (!password.trim() || loading) return
    setLoading(true); setError('')
    try {
      await api<AccessInfo>('/api/access/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password })
      })
      __accessLocked = false
      onUnlocked()
    } catch (e) {
      setError(e instanceof Error ? e.message : '登录失败')
    } finally {
      setLoading(false)
    }
  }
  return <div className="license-gate access-gate"><Card className="license-gate-card">
    <Typography.Title level={3} style={{ textAlign: 'center', marginTop: 0 }}><LockOutlined /> 访问验证</Typography.Title>
    <Typography.Paragraph type="secondary">此服务已启用访问密码。请输入密码后继续使用媒体库。</Typography.Paragraph>
    <Input.Password value={password} onChange={e => setPassword(e.target.value)} onPressEnter={login} size="large" placeholder="访问密码" autoFocus />
    <Button type="primary" block size="large" loading={loading} disabled={!password.trim()} onClick={login} style={{ marginTop: 12 }}>进入</Button>
    {error && <Alert type="error" showIcon message={error} style={{ marginTop: 12 }} />}
  </Card></div>
}

/** 图片加载失败自动重试：追加 retry=1 让后端跳过缓存回源，最多 2 次，仍失败则隐藏占位 */
function retryProxyImage(event: React.SyntheticEvent<HTMLImageElement>) {
  const img = event.currentTarget
  const step = Number(img.dataset.retryStep || '0')
  if (step >= 2) { img.style.visibility = 'hidden'; return }
  img.dataset.retryStep = String(step + 1)
  window.setTimeout(() => {
    try {
      const url = new URL(img.src, window.location.href)
      url.searchParams.set('retry', '1')
      url.searchParams.set('t', String(Date.now()))
      img.src = url.pathname + url.search
    } catch { img.src = img.src + (img.src.includes('?') ? '&' : '?') + 'retry=1&t=' + Date.now() }
  }, 1200 * (step + 1))
}

function AccessSecurityPanel({ configured, onChanged }: { configured?: boolean; onChanged: () => void }) {
  const [form] = Form.useForm()
  const [loading, setLoading] = useState(false)
  const savePassword = async () => {
    try {
      const values = await form.validateFields()
      setLoading(true)
      await api<AccessInfo & { message?: string }>('/api/access/password', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ current_password: values.current_password || '', new_password: values.new_password })
      })
      message.success('访问密码已保存')
      form.resetFields()
      await onChanged()
    } catch (e) {
      if (e instanceof Error) message.error(e.message)
    } finally {
      setLoading(false)
    }
  }
  const clearPassword = () => {
    let current = ''
    Modal.confirm({
      title: '关闭访问密码？',
      content: <div>
        <Typography.Text type="secondary">关闭后公网访问会直接进入页面，请确认外层还有反向代理认证或只在内网使用。</Typography.Text>
        <Input.Password placeholder="请输入当前访问密码以确认" style={{ marginTop: 12 }} onChange={event => { current = event.target.value }} />
      </div>,
      okText: '确认关闭',
      okButtonProps: { danger: true },
      cancelText: '取消',
      async onOk() {
        try {
          await api<AccessInfo & { message?: string }>('/api/access/password', {
            method: 'DELETE',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ current_password: current })
          })
          message.success('访问密码已关闭')
          form.resetFields()
          await onChanged()
        } catch (e) {
          message.error(e instanceof Error ? e.message : '关闭失败，请重试')
          throw e
        }
      }
    })
  }
  const logout = async () => {
    await api('/api/access/logout', { method: 'POST' })
    __accessLocked = true
    window.location.reload()
  }
  return <div style={{ maxWidth: 560 }}>
    <Alert type={configured ? 'success' : 'warning'} showIcon style={{ marginBottom: 16 }}
      message={configured ? '访问密码已启用' : '尚未启用访问密码'}
      description={configured ? '公网入口会先要求输入访问密码，登录后再进入授权和媒体页面。' : '如果要公网分享此服务，建议先设置访问密码。'} />
    <Form form={form} layout="vertical">
      {configured && <Form.Item name="current_password" label="当前访问密码" rules={[{ required: true, message: '请输入当前访问密码' }]}>
        <Input.Password placeholder="用于修改或关闭访问密码" />
      </Form.Item>}
      <Form.Item name="new_password" label={configured ? '新访问密码' : '访问密码'} rules={[{ required: true, message: '请输入访问密码' }, { min: 6, message: '至少 6 位' }]}>
        <Input.Password placeholder="建议使用不易猜测的密码" />
      </Form.Item>
      <Space wrap>
        <Button type="primary" icon={<LockOutlined />} loading={loading} onClick={savePassword}>{configured ? '更新访问密码' : '启用访问密码'}</Button>
        {configured && <Button danger icon={<DeleteOutlined />} onClick={clearPassword}>关闭访问密码</Button>}
        {configured && <Button icon={<LogoutOutlined />} onClick={logout}>退出当前登录</Button>}
      </Space>
    </Form>
  </div>
}

function App() {
  const [page, setPage] = useState('library')
  useEffect(() => {
    syncH5Class()
    window.addEventListener('resize', syncH5Class)
    window.visualViewport?.addEventListener('resize', syncH5Class)
    return () => {
      window.removeEventListener('resize', syncH5Class)
      window.visualViewport?.removeEventListener('resize', syncH5Class)
    }
  }, [])
  // 启动时先用 localStorage 缓存填充，避免空白转圈；后台再静默刷新
  const [catalogSection, setCatalogSection] = useState<CatalogSection>((loadCache<CatalogSection>('catalogSection') || 'latest'))
  const cachedFilms = loadCache<Film[]>(filmCacheKey(catalogSection, 'films'))
  const cachedPage = loadCache<number>(filmCacheKey(catalogSection, 'catalogPage'))
  const cachedHasNext = loadCache<boolean>(filmCacheKey(catalogSection, 'hasNextPage'))
  const [films, setFilms] = useState<Film[]>(cachedFilms || [])
  const [catalogPage, setCatalogPage] = useState(cachedPage || 1)
  const [hasNextPage, setHasNextPage] = useState(cachedHasNext || false)
  const [selected, setSelected] = useState<Film | null>(null)
  const [filmDetail, setFilmDetail] = useState<FilmDetail | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [captured, setCaptured] = useState<Capture | null>(null)
  // 有缓存时启动不显示 loading（后台静默刷新）；没缓存才显示
  const [loading, setLoading] = useState(!cachedFilms)
  const [captureLoading, setCaptureLoading] = useState(false)
  const [localLoading, setLocalLoading] = useState(false)
  const [cloudLoading, setCloudLoading] = useState(false)
  const [cloudRefreshing, setCloudRefreshing] = useState(false)
  const [manualScrapeOpen, setManualScrapeOpen] = useState(false)
  const [manualScrapeLoading, setManualScrapeLoading] = useState(false)
  const [manualScrapeForm] = Form.useForm()
  const [downloads, setDownloads] = useState<DownloadTask[]>(loadCache<DownloadTask[]>(CACHE_KEYS.downloads) || [])
  const [cloudTasks, setCloudTasks] = useState<CloudTask[]>(loadCache<CloudTask[]>(CACHE_KEYS.cloudTasks) || [])
  const [hgTasks, setHgTasks] = useState<HgEpisodeTask[]>([])
  const [heroStats, setHeroStats] = useState<HeroStats | null>(null)
  const [strmItems, setStrmItems] = useState<StrmItem[]>([])
  const [playingStrm, setPlayingStrm] = useState<StrmItem | null>(null)
  const [playingPickcode, setPlayingPickcode] = useState<{ pickcode: string; title: string } | null>(null)
  const [playingLocal, setPlayingLocal] = useState<{ name: string; path: string } | null>(null)
  const [playLoading, setPlayLoading] = useState(false)
  const [playError, setPlayError] = useState<string>('')
  const [cloudOpen, setCloudOpen] = useState(false)
  const [qrInfo, setQrInfo] = useState<QRInfo | null>(null)
  const [qrClient, setQrClient] = useState('android')
  const [check115Loading, setCheck115Loading] = useState(false)
  const [signinLoading, setSigninLoading] = useState(false)
  const [signinStatus, setSigninStatus] = useState<SigninStatus | null>(null)
  const [adCleanupLoading, setAdCleanupLoading] = useState(false)
  const [check115Result, setCheck115Result] = useState<{ ok: boolean; message: string } | null>(null)
  const [settings, setSettings] = useState<Settings | null>(loadCache<Settings>(CACHE_KEYS.settings) || null)
  const [settingsForm] = Form.useForm<Settings>()
  const [cloudForm] = Form.useForm()
  const [filmSearch, setFilmSearch] = useState('')
  const [settingsTab, setSettingsTab] = useState('network')
  const [logModulePreset, setLogModulePreset] = useState('all')
  const currentLocalTasks = useMemo(() => downloads.filter(item => selected && item.catalog === selected.catalog), [downloads, selected])
  const currentCloudTasks = useMemo(() => cloudTasks.filter(item => selected && (item.detail_url === selected.detail_url || item.catalog === selected.catalog)), [cloudTasks, selected])
  const filteredFilms = useMemo(() => {
    const q = filmSearch.trim().toLowerCase()
    if (!q) return films
    return films.filter(f =>
      (f.catalog || '').toLowerCase().includes(q) ||
      (f.title || '').toLowerCase().includes(q)
    )
  }, [films, filmSearch])

  // silent=true 时为后台静默刷新，不显示 loading（用于启动时已有缓存的情况）
  const loadFilms = async (refresh = false, pageNumber = catalogPage, silent = false, section = catalogSection) => {
    if (!silent) setLoading(true)
    try {
      const params = new URLSearchParams({ page: String(pageNumber), section })
      if (refresh) params.set('refresh', '1')
      const result = await api<CatalogPage>(`/api/jable/catalog?${params.toString()}`)
      setFilms(result.items); setCatalogPage(result.page); setHasNextPage(result.has_next)
      saveCache(filmCacheKey(section, 'films'), result.items)
      saveCache(filmCacheKey(section, 'catalogPage'), result.page)
      saveCache(filmCacheKey(section, 'hasNextPage'), result.has_next)
    }
    catch (error) { if (!silent) message.error(error instanceof Error ? error.message : '影片列表加载失败') }
    finally { if (!silent) setLoading(false) }
  }
  const changeCatalogSection = (section: CatalogSection) => {
    setCatalogSection(section)
    saveCache('catalogSection', section)
    const nextFilms = loadCache<Film[]>(filmCacheKey(section, 'films')) || []
    const nextPage = loadCache<number>(filmCacheKey(section, 'catalogPage')) || 1
    const nextHasNext = loadCache<boolean>(filmCacheKey(section, 'hasNextPage')) || false
    setFilms(nextFilms); setCatalogPage(nextPage); setHasNextPage(nextHasNext); setSelected(null)
    loadFilms(false, nextPage, !!nextFilms.length, section)
  }
  const loadTasks = async () => {
    try {
      const [local, cloud, hero, hgEpisodes] = await Promise.all([
        api<DownloadTask[]>('/api/tasks'), api<CloudTask[]>('/api/cloud-tasks'),
        api<HeroStats>('/api/hero-stats').catch(() => null),
        api<HgEpisodeTask[]>('/api/hg/recent-episodes?limit=150').catch(() => null),
      ])
      setDownloads(local); setCloudTasks(cloud)
      if (hgEpisodes) setHgTasks(hgEpisodes)
      if (hero) setHeroStats(hero)
      saveCache(CACHE_KEYS.downloads, local, 1000 * 60 * 5)  // 任务列表缓存 5 分钟
      saveCache(CACHE_KEYS.cloudTasks, cloud, 1000 * 60 * 5)
    } catch { /* Background refresh must not interrupt browsing. */ }
  }
  const retryHgEpisode = async (episodeId: string) => {
    try { await api(`/api/hg/episodes/${episodeId}/download`, { method: 'POST' }); message.success('已重新排队下载'); loadTasks() }
    catch (error) { message.error(error instanceof Error ? error.message : '重试失败') }
  }
  const loadCloudTasks = async () => {
    setCloudRefreshing(true)
    try {
      const cloud = await api<CloudTask[]>('/api/cloud-tasks')
      setCloudTasks(cloud); saveCache(CACHE_KEYS.cloudTasks, cloud, 1000 * 60 * 5)
    } catch { /* ignore */ }
    finally { setCloudRefreshing(false) }
  }
  const refreshCloudNow = async (notify = true) => {
    setCloudRefreshing(true)
    try {
      const result = await api<any>('/api/cloud-tasks/poll-now', { method: 'POST' })
      if (notify) message.success(result.message || `轮询完成：${result.completed} 个任务更新`)
    } catch (error) {
      if (notify) message.warning(error instanceof Error ? error.message : '轮询请求失败，改为从 DB 读取')
    }
    await loadCloudTasks()
  }
  const refreshAfterCloudSubmit = async () => {
    await loadTasks()
    await refreshCloudNow(false)
    loadStrmLibrary()
    window.setTimeout(() => {
      refreshCloudNow(false)
      loadStrmLibrary()
    }, 3000)
  }
  const loadStrmLibrary = async (retry = false) => {
    try {
      const items = await api<StrmItem[]>('/api/strm-library')
      setStrmItems(items)
      // 有条目缺封面时，后端正在后台补抓；15 秒后自动刷新一次显示结果
      if (!retry && items.some(item => !item.poster_path && !item.cover_url)) {
        setTimeout(() => loadStrmLibrary(true), 15000)
      }
    } catch { /* ignore */ }
  }
  // 115 播放：先 resolve 预热后端直链缓存（避免 video 标签首次 Range 请求等 resolve 超时）
  const playPickcode = async (pc: string, title: string) => {
    setPlayingPickcode({ pickcode: pc, title })
    setPlayLoading(true)
    setPlayError('')
    try {
      const r = await fetch(`/api/115/resolve/${pc}`)
      const d = await r.json().catch(() => ({}))
      if (!r.ok || !d.url) {
        setPlayError(d.error || d.message || `获取直链失败 (HTTP ${r.status})`)
      }
    } catch (e) {
      setPlayError(e instanceof Error ? e.message : '获取直链失败')
    } finally {
      setPlayLoading(false)
    }
  }
  const playStrm = (item: StrmItem) => {
    // 如果有 pickcode 直接用 pickcode 播放（云下载完成但未开管线D的情况）
      if (item.pickcode) {
      playPickcode(item.pickcode, item.title)
    } else {
      setPlayingStrm(item)
    }
  }
  const deleteStrmItem = async (id: string) => {
    try {
      await api(`/api/strm-library/${id}`, { method: 'DELETE' })
      message.success('已从媒体库删除'); loadStrmLibrary(); loadCloudTasks()
    } catch (error) { message.error(error instanceof Error ? error.message : '删除失败') }
  }
  // 启动:有缓存就静默刷新(films 不带 refresh 走后端缓存),没缓存才显示 loading
  useEffect(() => {
    if (page === 'medialib') { loadStrmLibrary() }
    if (page === 'settings') { reloadSettingsForm(); loadSigninStatus() }
  }, [page])
  useEffect(() => {
    // 隐私模式效果
    const enabled = settings?.privacy_mode !== false
    document.body.classList.toggle('privacy-mode', enabled)
  }, [settings?.privacy_mode])
  useEffect(() => {
    const openLogCenter = (event: Event) => {
      const detail = (event as CustomEvent<{ module?: string }>).detail
      setPage('settings')
      setSettingsTab('logs')
      setLogModulePreset(detail?.module || 'all')
    }
    window.addEventListener('jable-open-log-center', openLogCenter)
    return () => window.removeEventListener('jable-open-log-center', openLogCenter)
  }, [])
  useEffect(() => {
    const hasCache = !!cachedFilms
    loadFilms(false, cachedPage || 1, hasCache, catalogSection)
    loadTasks(); loadSettings()
    const timer = window.setInterval(loadTasks, 3000)
    return () => window.clearInterval(timer)
  }, [])

  // 首页工具栏快捷切换隐私模式（封面模糊）
  const togglePrivacyMode = async (checked: boolean) => {
    const next = { ...(settings || {}), privacy_mode: checked } as Settings
    setSettings(next); saveCache(CACHE_KEYS.settings, next)
    document.body.classList.toggle('privacy-mode', checked)
    try {
      await api('/api/settings', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ privacy_mode: checked }) })
      message.success(checked ? '隐私模式已开启：封面已模糊' : '隐私模式已关闭：封面正常显示')
    } catch { message.error('保存失败'); loadSettings() }
  }
  const loadSettings = async () => {
    try { const s = await api<Settings>('/api/settings'); setSettings(s); saveCache(CACHE_KEYS.settings, s) } catch { /* ignore */ }
  }
  const reloadSettingsForm = async () => {
    try { const s = await api<Settings>('/api/settings'); setSettings(s); settingsForm.setFieldsValue(s) } catch { /* ignore */ }
  }
  // 点击 115 相关操作前检查配置；未配置则提示并跳转到服务设置页
  const ensure115Configured = async (): Promise<boolean> => {
    let s = settings
    if (!s) {
      try { s = await api<Settings>('/api/settings'); setSettings(s) } catch { s = null }
    }
    if (!s) { message.error('无法读取服务设置，请稍后重试'); return false }
    const mode = s.cloud115_mode || 'bridge'
    const ready = mode === 'cookie' ? !!s.cloud115_cookie_configured : !!s.cloud115_endpoint?.trim()
    if (!ready) {
      message.warning(mode === 'cookie' ? '请先在服务设置中保存 115 Cookie 或扫码登录' : '请先在服务设置中填写 115 中转服务地址')
      try { settingsForm.setFieldsValue(s) } catch { /* ignore */ }
      reloadSettingsForm()
      setPage('settings')
      return false
    }
    return true
  }
  const [savingSettings, setSavingSettings] = useState(false)
  const saveSettings = async () => {
    setSavingSettings(true)
    try {
      await api('/api/settings', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(settingsForm.getFieldsValue()) })
      message.success('设置已保存'); setQrInfo(null); await loadSettings(); loadFilms(true, catalogPage)
    } catch (error) { message.error(error instanceof Error ? error.message : '保存失败') } finally { setSavingSettings(false) }
  }
  const generateQr = async () => {
    try {
      setQrInfo(await api<QRInfo>('/api/115/qrcode', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ client: qrClient }) }))
      setQrStatus('等待扫码')
      message.success('二维码已生成，请用 115 手机客户端扫码')
      startQrPoll()
    }
    catch (error) { message.error(error instanceof Error ? error.message : '二维码生成失败') }
  }
  const qrPollRef = useRef<number | null>(null)
  const [qrStatus, setQrStatus] = useState('')
  const stopQrPoll = () => { if (qrPollRef.current) { window.clearInterval(qrPollRef.current); qrPollRef.current = null } }
  const startQrPoll = () => {
    stopQrPoll()
    let attempts = 0
    qrPollRef.current = window.setInterval(async () => {
      attempts += 1
      if (attempts > 80) { stopQrPoll(); setQrStatus('二维码已超时，请重新生成'); return }
      try {
        const status = await api<{ status: string; message: string }>('/api/115/qrcode/status')
        if (status.status === 'authorized') {
          stopQrPoll(); setQrInfo(null); setQrStatus('')
          message.success('115 登录成功，Cookie 已保存')
          check115Login()
        } else if (status.status === 'scanned') setQrStatus('已扫码，请在手机上确认登录')
      } catch { /* 轮询失败静默重试 */ }
    }, 2500)
  }
  useEffect(() => stopQrPoll, [])
  const pollQr = async () => {
    try {
      const status = await api<{ status: string; message: string }>('/api/115/qrcode/status')
      if (status.status === 'authorized') {
        stopQrPoll(); setQrInfo(null); setQrStatus('')
        message.success('115 登录成功，Cookie 已保存')
        check115Login()
      } else { setQrStatus(status.message); message.info(status.message) }
    } catch (error) { message.error(error instanceof Error ? error.message : '扫码状态检查失败') }
  }
  const [proxyTesting, setProxyTesting] = useState(false)
  const [proxyTestResult, setProxyTestResult] = useState<{ ok: boolean; message: string } | null>(null)
  const testProxy = async () => {
    setProxyTesting(true); setProxyTestResult(null)
    try {
      const proxyValue = String(settingsForm.getFieldValue('proxy') || '').trim()
      setProxyTestResult(await api<{ ok: boolean; message: string }>('/api/proxy-test', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ proxy: proxyValue }) }))
    } catch (error) { setProxyTestResult({ ok: false, message: error instanceof Error ? error.message : '检测失败' }) }
    finally { setProxyTesting(false) }
  }
  // 手动检测 115 登录状态（Cookie 模式查 115，中转模式探活服务）
  const runAdCleanup = async () => {
    setAdCleanupLoading(true)
    try {
      const result = await api<{ ok: boolean; message?: string }>('/api/115/cleanup-ads', { method: 'POST' })
      message.success(result.message || '后台清理已启动')
    } catch (error) {
      message.error(error instanceof Error ? error.message : '清理请求失败')
    } finally { setAdCleanupLoading(false) }
  }
  const check115Login = async () => {
    setCheck115Loading(true); setCheck115Result(null)
    try {
      setCheck115Result(await api<{ ok: boolean; message: string }>('/api/115/check-login', { method: 'POST' }))
    } catch (error) {
      setCheck115Result({ ok: false, message: error instanceof Error ? error.message : '检测失败' })
    } finally { setCheck115Loading(false) }
  }
  const loadSigninStatus = async () => {
    try { setSigninStatus(await api<SigninStatus>('/api/115/signin')) } catch { /* ignore */ }
  }
  const run115Signin = async () => {
    setSigninLoading(true)
    try {
      const result = await api<SigninStatus>('/api/115/signin', { method: 'POST' })
      setSigninStatus(result)
      message.success(result.message || result.logs?.[0]?.message || '115 签到完成')
    } catch (error) {
      message.error(error instanceof Error ? error.message : '115 签到失败')
      loadSigninStatus()
    } finally { setSigninLoading(false) }
  }
  const chooseFilm = (film: Film) => { setSelected(film); setCaptured(null); setFilmDetail(null) }
  useEffect(() => {
    if (!selected) return
    let cancelled = false
    const loadDetail = async () => {
      setDetailLoading(true)
      try {
        const params = new URLSearchParams({ detail_url: selected.detail_url, duration: selected.duration || '' })
        const detail = await api<FilmDetail>(`/api/jable/detail?${params.toString()}`)
        if (!cancelled) setFilmDetail(detail)
      } catch (error) {
        if (!cancelled) message.warning(error instanceof Error ? error.message : '详情扩展信息加载失败')
      } finally {
        if (!cancelled) setDetailLoading(false)
      }
    }
    loadDetail()
    return () => { cancelled = true }
  }, [selected])
  const captureMedia = async () => {
    if (!selected) return null
    setCaptureLoading(true)
    try {
      const result = await api<Capture>('/api/jable/capture', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ detail_url: selected.detail_url }) })
      setCaptured(result); message.success('已抓取 M3U8')
      return result
    } catch (error) { message.error(error instanceof Error ? error.message : '媒体抓取失败'); return null }
    finally { setCaptureLoading(false) }
  }
  const addLocal = async () => {
    if (!selected) return
    setLocalLoading(true)
    try {
      await api('/api/jable/auto-task', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ detail_url: selected.detail_url }) })
      message.success('已加入本地下载队列'); loadTasks()
    } catch (error) { message.error(error instanceof Error ? error.message : '自动下载失败') }
    finally { setLocalLoading(false) }
  }
  const addCloudFromDetail = async () => {
    if (!selected) return
    if (!(await ensure115Configured())) return
    setCloudLoading(true)
    try {
      const result = await api<{ media_url: string }>('/api/jable/auto-cloud-task', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(selected) })
      if (result.media_url) setCaptured({ detail_url: selected.detail_url, title: selected.title, catalog: selected.catalog, media_url: result.media_url })
      message.success('已抓取并提交到 115'); await refreshAfterCloudSubmit()
    } catch (error) { message.error(error instanceof Error ? error.message : '提交 115 失败') }
    finally { setCloudLoading(false) }
  }
  const addCloud = async () => {
    if (!(await ensure115Configured())) return
    try {
      const values = await cloudForm.validateFields()
      setCloudLoading(true)
      await api('/api/cloud-tasks', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...values, title: selected?.title, catalog: selected?.catalog, detail_url: selected?.detail_url }) })
      message.success('已提交至 115'); setCloudOpen(false); cloudForm.resetFields(); await refreshAfterCloudSubmit()
    } catch (error) { if (error instanceof Error) message.error(error.message) }
    finally { setCloudLoading(false) }
  }
  const addCloudUrl = async (sourceUrl: string, title?: string) => {
    if (!selected) return
    if (!(await ensure115Configured())) return
    setCloudLoading(true)
    try {
      await api('/api/cloud-tasks', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ source_url: sourceUrl, title: title || selected.title, catalog: selected.catalog, detail_url: selected.detail_url })
      })
      message.success('已提交至 115'); await refreshAfterCloudSubmit()
    } catch (error) { message.error(error instanceof Error ? error.message : '提交 115 失败') }
    finally { setCloudLoading(false) }
  }
  const deleteCloud = async (id: string) => {
    try {
      await api(`/api/cloud-tasks/${id}`, { method: 'DELETE' })
      message.success('已删除任务记录'); loadCloudTasks()
    } catch (error) { message.error(error instanceof Error ? error.message : '删除失败') }
  }
  const submitManualScrape = async () => {
    try {
      const values = await manualScrapeForm.validateFields()
      setManualScrapeLoading(true)
      const result: any = await api('/api/manual-scrape', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ paths: values.paths })
      })
      const ids: string[] = result.ids || []
      message.success(`已创建 ${ids.length} 个手动刮削任务` + (result.warnings?.length ? `（${result.warnings.length} 个警告）` : ''))
      setManualScrapeOpen(false); manualScrapeForm.resetFields(); loadTasks()
    } catch (error) { if (error instanceof Error) message.error(error.message) }
    finally { setManualScrapeLoading(false) }
  }
  const localCount = downloads.filter(item => item.state === 'running').length
  const completeCount = downloads.filter(item => item.state === 'completed').length
  const cloudActiveCount = cloudTasks.filter(item => item.state !== 'completed' && item.state !== 'failed').length
  const hgActiveCount = hgTasks.filter(item => item.state === 'queued' || item.state === 'running').length
  const activeCount = localCount + cloudActiveCount + hgActiveCount
  // 访问门禁:启用访问密码后，先登录再进入授权和业务页面
  const [accessState, setAccessState] = useState<'pending' | 'ok' | 'locked'>('pending')
  const reloadAccessState = async () => {
    const info = await api<AccessInfo>('/api/access/status')
    __accessLocked = info.configured && !info.authenticated
    setAccessState(__accessLocked ? 'locked' : 'ok')
    return info
  }
  useEffect(() => { reloadAccessState().catch(() => setAccessState('locked')) }, [])
  // 授权门禁:未授权时整站锁定,仅渲染授权页(后端同步拦截所有非白名单接口)
  const [licenseState, setLicenseState] = useState<'pending' | 'ok' | 'locked'>('pending')
  useEffect(() => {
    if (accessState !== 'ok') return
    api<LicenseInfo>('/api/license').then(info => { __unlicensed = !info.activated; setLicenseState(info.activated ? 'ok' : 'locked') }).catch(() => setLicenseState('locked'))
  }, [accessState])
  if (accessState === 'pending') return <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Spin size="large" /></div>
  if (accessState === 'locked') return <AccessGate onUnlocked={() => { setAccessState('ok'); window.location.reload() }} />
  if (licenseState === 'pending') return <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Spin size="large" /></div>
  if (licenseState === 'locked') return <LicenseGate onActivated={() => window.location.reload()} />

  return <>
    <Layout className={`shell page-${page}`}>
      <Layout.Sider width={236} className="sidebar">
        <div className="brand"><span className="brand-mark">J</span><div><strong>Jable 媒体库</strong><small>家庭影音中心</small></div></div>
        <Menu className="app-menu" theme="dark" mode="inline" selectedKeys={[page]} onClick={({ key }) => { setPage(key); if (key === 'settings') { reloadSettingsForm() } }} items={[
          { key: 'library', icon: <VideoCameraOutlined />, label: '影片浏览' },
          { key: 'huangguo', icon: <CloudUploadOutlined />, label: '黄果短剧' },
          { key: 'tasks', icon: <CloudDownloadOutlined />, label: <span>下载任务 <Badge count={activeCount} size="small" /></span> },
          { key: 'medialib', icon: <PlaySquareOutlined />, label: '媒体库' },
          { key: 'settings', icon: <SettingOutlined />, label: '服务设置' }
        ]} />
        <div className="sidebar-foot"><span>v1.1 · Docker</span></div>
      </Layout.Sider>
      <Layout>
        <Layout.Content className="content">
          <div className="mobile-topbar">
            <span className="brand-mark">J</span>
            <div>
              <strong>Jable</strong>
              <small>{page === 'library' ? '影片浏览' : page === 'huangguo' ? '黄果短剧' : page === 'tasks' ? '下载任务' : page === 'medialib' ? '媒体库' : '服务设置'}</small>
            </div>
          </div>
          {page === 'library' && <><section className="hero"><div className="hero-stats"><Statistic title="正在下载" value={localCount} suffix="项" /><Statistic title="已整理" value={completeCount} suffix="部" /><Statistic title="115 离线中" value={heroStats?.cloud_active ?? 0} suffix="项" /><Statistic title="115 已离线" value={heroStats?.cloud_done ?? 0} suffix="部" /><Statistic title="媒体库" value={heroStats?.strm_count ?? 0} suffix="部" /><Statistic title="今日自动离线" value={heroStats?.auto_today ?? 0} suffix="部" /></div></section><div className="toolbar-row"><Space wrap size={8}><Segmented value={catalogSection} onChange={value => changeCatalogSection(value as CatalogSection)} options={[{ label: '最新', value: 'latest' }, { label: '中文专区', value: 'chinese' }]} /><Input.Search placeholder="按番号或标题搜索..." allowClear enterButton="搜索" style={{ width: 360, maxWidth: '100%' }} value={filmSearch} onChange={e => setFilmSearch(e.target.value)} onSearch={q => setFilmSearch(q)} /></Space><Space wrap size={8}><Switch checked={settings?.privacy_mode !== false} onChange={togglePrivacyMode} checkedChildren="隐私模式" unCheckedChildren="隐私模式" /><Button icon={<ReloadOutlined />} onClick={() => loadFilms(true, catalogPage)}>刷新</Button><Button icon={<FolderOpenOutlined />} onClick={() => setManualScrapeOpen(true)}>刮削 strm</Button><Button type="primary" icon={<PlusOutlined />} onClick={() => setCloudOpen(true)}>新建离线</Button></Space></div><Spin spinning={loading}><FilmGrid films={filteredFilms} onSelect={chooseFilm} /><div className="catalog-pagination"><Pagination current={catalogPage} pageSize={24} total={hasNextPage ? catalogPage * 24 + 24 : Math.max(catalogPage * 24, films.length)} showSizeChanger={false} onChange={(nextPage) => loadFilms(false, nextPage)} /></div></Spin></>}
          {page === 'huangguo' && <HuangguoPage onPlayLocal={item => setPlayingLocal(item)} />}
          {page === 'tasks' && <TaskListPage downloads={downloads} cloudTasks={cloudTasks} hgTasks={hgTasks} onDeleteCloud={deleteCloud} onPlayStrm={playStrm} onPlayPickcode={playPickcode} onRefresh={loadTasks} refreshing={cloudRefreshing} onPoll115={refreshCloudNow} onRetryHg={retryHgEpisode} />}
          {page === 'medialib' && <MediaLibraryPage strmItems={strmItems} onPlayStrm={playStrm} onDeleteStrm={deleteStrmItem} onPlayLocal={item => setPlayingLocal({ name: item.name, path: item.path })} onRefresh={loadStrmLibrary} />}
          {page === 'settings' && <>
            <div className="toolbar-row" style={{ marginBottom: 16 }}>
              <Typography.Title level={4} style={{ margin: 0 }}>服务设置</Typography.Title>
              <Space wrap size={8}>
                <Button icon={<ReloadOutlined />} onClick={reloadSettingsForm}>重新加载</Button>
                <Button type="primary" icon={<SettingOutlined />} loading={savingSettings} onClick={saveSettings}>保存设置</Button>
              </Space>
            </div>
            <Card>
              <Form form={settingsForm} layout="vertical">
                <Tabs activeKey={settingsTab} onChange={setSettingsTab} items={[
                  { key: 'network', label: '网络代理', children: <><Form.Item name="threads" label="本地下载线程"><InputNumber min={1} max={32} style={{ width: '100%' }} /></Form.Item><Form.Item name="proxy" label="代理地址"><Input placeholder="http://192.168.2.1:7890 或 socks5://host:port" /></Form.Item><Form.Item label="代理连通检测" tooltip="用上方代理地址访问外网测试可达性，可检测未保存的输入值"><Space wrap><Button icon={<ApiOutlined />} loading={proxyTesting} onClick={testProxy}>检测连通</Button>{proxyTestResult && <Typography.Text type={proxyTestResult.ok ? 'success' : 'danger'}>{proxyTestResult.message}</Typography.Text>}</Space></Form.Item><Form.Item name="jable_cookie" label="Jable Cookie"><Input.Password placeholder={settingsForm.getFieldValue('jable_cookie_configured') ? '已保存，留空保持不变' : '从可访问 Jable 的浏览器复制 Cookie'} /></Form.Item><Divider orientation="left" plain>隐私保护</Divider><Form.Item name="privacy_mode" valuePropName="checked" label="隐私模式" tooltip="开启后所有影片封面自动模糊（防止截屏/投屏泄露），鼠标悬停时轻微清晰化"><Switch checkedChildren="封面模糊" unCheckedChildren="正常显示" /></Form.Item></> },
                  { key: 'access', label: '访问安全', children: <AccessSecurityPanel configured={settings?.site_password_configured} onChanged={reloadSettingsForm} /> },
                  { key: 'paths', label: '路径配置', children: <PathPipelineConfig settingsForm={settingsForm} /> },
                  { key: 'auto-offline', label: '自动离线', children: <AutoOfflineCard settingsForm={settingsForm} /> },
                  { key: 'huangguo', label: '黄果短剧', children: <><Alert type="info" showIcon message="黄果短剧流程" description="固定顺序：解析短剧 → 下载单集 → 合并转封装 → 完整刮削 → 本地入库。默认连载剧不上传，手动标记全剧完结后再进入 115 上传队列。" style={{ marginBottom: 16 }} /><Form.Item name="hg_upload_strategy" label="上传策略"><Radio.Group optionType="button" buttonStyle="solid" options={[{ label: '完结后上传', value: 'completed' }, { label: '每集完成即上传', value: 'episode' }, { label: '不上传', value: 'never' }]} /></Form.Item><Form.Item name="hg_delete_after_upload" valuePropName="checked" label="上传成功后删除本地源文件" tooltip="仅在 115 上传明确成功并写入数据库后才会删除视频文件；metadata/poster 会保留"><Switch checkedChildren="删除源文件" unCheckedChildren="保留源文件" /></Form.Item><Form.Item name="hg_target_cid" label="115 目标目录" tooltip="从 115 网盘中选择黄果短剧上传目录，会自动保存目录 ID 和路径"><Dir115TreeSelect placeholder="选择 115 网盘中的黄果短剧目录" onPathChange={(path) => settingsForm.setFieldValue('hg_target_path', path ? `/${path}` : '/黄果短剧')} /></Form.Item><Form.Item name="hg_target_path" label="当前目录路径"><Input placeholder="/黄果短剧" readOnly /></Form.Item><Form.Item name="hg_check_interval" label="追更检查间隔（小时）"><InputNumber min={1} max={72} style={{ width: '100%' }} /></Form.Item><Form.Item name="hg_follow_enabled" valuePropName="checked" label="自动追更开关" tooltip="关闭后不再定期检查追剧库中连载剧的新集"><Switch checkedChildren="开启" unCheckedChildren="关闭" /></Form.Item><Form.Item name="hg_follow_pages" label="每轮追更检查剧集数" tooltip="每轮追更最多检查多少部剧（按最久未检查优先分批轮询，避免单轮请求过多触发风控）"><InputNumber min={1} max={20} style={{ width: '100%' }} /></Form.Item><Divider orientation="left" plain>下载与扫描</Divider><Form.Item name="hg_episode_concurrency" label="集数并行下载线程数" tooltip="同时下载的集数，1=串行；建议 2-3，过高可能触发站点风控"><InputNumber min={1} max={4} style={{ width: '100%' }} /></Form.Item><Form.Item name="hg_site_mirrors" label="备用镜像域名" tooltip="当前域名不可达（404/连接重置）时按顺序自动切换，成功后全局生效；多个用逗号或换行分隔"><Input.TextArea rows={2} placeholder="https://a.example.cc, https://b.example.cc" /></Form.Item><Form.Item name="hg_use_proxy" valuePropName="checked" label="下载视频使用代理" tooltip="开启后黄果视频下载走「网络代理」里配置的代理；列表/详情/封面抓取始终直连。站点直连速度快时可关闭"><Switch checkedChildren="走代理" unCheckedChildren="直连" /></Form.Item></> },
                  { key: '115', label: '115 登录', children: <><Form.Item name="cloud115_mode" label="离线模式"><Radio.Group optionType="button" buttonStyle="solid" options={[{ label: '中转服务', value: 'bridge' }, { label: 'Cookie 直连', value: 'cookie' }]} /></Form.Item><Form.Item name="cloud115_endpoint" label="中转服务地址" tooltip="使用中转服务模式时填写，后端会把离线任务提交到这个 HTTP/HTTPS 地址"><Input placeholder="https://your-115-bridge.example.com/task" /></Form.Item><Form.Item name="cloud115_token" label="中转服务 Token"><Input.Password placeholder={settingsForm.getFieldValue('cloud115_token_configured') ? '已保存，留空保持不变' : '可选，提交任务时作为 Bearer Token'} /></Form.Item><Form.Item name="cloud115_cookie" label="115 Cookie"><Input.Password placeholder={settingsForm.getFieldValue('cloud115_cookie_configured') ? '已保存，留空保持不变' : 'Cookie 直连模式使用，或扫码登录自动保存'} /></Form.Item><Divider orientation="left" plain>在线播放</Divider><Form.Item name="cloud115_play_mode" label="播放方式" tooltip="代理流式：视频经后端转发，兼容性最好；302 直连：浏览器直连 115 CDN，不占用后端带宽，若个别视频无法播放可切回代理流式"><Radio.Group optionType="button" buttonStyle="solid" options={[{ label: '代理流式', value: 'proxy' }, { label: '302 直连', value: 'redirect' }]} /></Form.Item><Form.Item name="cloud_ad_min_mb" label="离线产物广告清理阈值(MB)" tooltip="115 离线完成后自动删除产物目录内小于该体积的文件（不限后缀，含子目录；请勿设置过大以免误删正片），0=关闭；逐个低频删除（间隔 1.5 秒、单次最多 80 个）以避免触发 115 风控"><InputNumber min={0} max={500} style={{ width: 160 }} /></Form.Item><Form.Item label="广告清理操作" tooltip="立即按当前阈值清理最近完成的离线产物目录（后台执行，不限后缀，含子目录）"><Popconfirm title="立即清理已入库的离线目录？" description="将删除最近完成产物目录内所有小于阈值的小文件（不限后缀，含子目录）。" okText="开始清理" cancelText="取消" onConfirm={runAdCleanup}><Button icon={<ClearOutlined />} loading={adCleanupLoading}>立即清理已入库目录</Button></Popconfirm></Form.Item><Alert type="info" showIcon message="扫码端和签到端已分开适配" description="下方选择的是请求 115 二维码/换 Cookie 的客户端类型；115 手机 App 的授权标题可能仍显示 Windows/网页字样，以最终保存的 Cookie 为准。自动签到会依次尝试 Android、iOS、网页版接口，任意一路成功即记为成功。" style={{ marginBottom: 12 }} /><Space wrap><Select value={qrClient} onChange={(v: string) => setQrClient(v)} style={{ minWidth: 170 }} options={[{ value: 'android', label: 'Android 客户端' }, { value: 'ios', label: 'iOS 客户端' }, { value: 'web', label: '网页版' }, { value: 'windows', label: 'Windows 客户端' }, { value: 'mac', label: 'macOS 客户端' }, { value: 'linux', label: 'Linux 客户端' }, { value: 'tv', label: 'TV 客户端' }, { value: 'wechatmini', label: '微信小程序' }, { value: 'alipaymini', label: '支付宝小程序' }]} /><Button icon={<QrcodeOutlined />} onClick={generateQr}>生成扫码登录</Button>{qrInfo && <Button type="primary" onClick={pollQr}>我已确认，检查登录</Button>}<Button icon={<SafetyOutlined />} loading={check115Loading} onClick={check115Login}>检测登录状态</Button></Space>{check115Result && <Alert type={check115Result.ok ? 'success' : 'error'} showIcon message={check115Result.message} style={{ marginTop: 12 }} />}{qrInfo && <div className="qr-box">{qrInfo.image ? <img src={qrInfo.image} alt="115 登录二维码" /> : <Typography.Link href={qrInfo.qrcode} target="_blank">打开二维码链接</Typography.Link>}{qrStatus && <div className="qr-status">{qrStatus}</div>}</div>}</> },
                  { key: 'usage', label: '使用说明', children: <Typography>
                    <Typography.Title level={5} style={{ marginTop: 0 }}>整体流程</Typography.Title>
                    <Typography.Paragraph>影片浏览找片 → 详情页发起「本地下载」或「离线到 115」→ 在「下载任务」看进度 → 完成后自动进入「媒体库」直接播放。</Typography.Paragraph>
                    <Typography.Title level={5}>影片浏览</Typography.Title>
                    <ul>
                      <li>搜索番号/标题、翻页浏览；点封面打开详情（样张、磁力链接、文件信息）。</li>
                      <li>详情页可发起本地下载入库、115 离线、手动刮削整理。</li>
                    </ul>
                    <Typography.Title level={5}>下载任务</Typography.Title>
                    <ul>
                      <li>本地下载与 115 离线任务合并展示，可按来源筛选、按番号搜索。</li>
                      <li>本地任务失败可重试；115 任务可直接播放或删除；右上角「同步 115」立即拉取最新状态（平时每 3 秒自动刷新）。</li>
                    </ul>
                    <Typography.Title level={5}>媒体库</Typography.Title>
                    <ul>
                      <li>115 与本地影片合并展示，带来源标签，支持来源筛选与搜索。</li>
                      <li>播放方式在「115 登录」页签设置：302 直连不占后端带宽（115 大文件必须用此方式）；个别视频放不出来可切回代理流式。</li>
                    </ul>
                    <Typography.Title level={5}>自动离线</Typography.Title>
                    <ul>
                      <li>在「自动离线」页签开启后，按计划定时和浏览触发自动提交 115 离线，支持白名单、最短时长、最小体积、每日上限等过滤条件。</li>
                    </ul>
                    <Typography.Title level={5}>四条管线（路径配置）</Typography.Title>
                    <ul>
                      <li><b>管线 A · 本地下载：</b>影片详情页点「本地下载入库」触发。流程：Jable 下载 → 刮削（封面/nfo/演员）→ 转移到本地目录（默认 /media/演员/番号/）。可关闭刮削（只下载）或关闭转移（留在原地）。</li>
                      <li><b>管线 B · 手动刮削（strm）：</b>详情页「手动刮削 strm」按钮或 Watch Folder 监控触发。流程：整理已有文件 → 刮削 → 转移到本地目录。开启监控后，监控目录里放入 .strm/.mp4/.mkv 等文件会自动刮削（写入中的文件自动跳过）。</li>
                      <li><b>管线 C · 115 网盘内秒转移：</b>提交离线任务时自动生效。提交时直接指定 115 目标目录，产物下载完成即落位，无需再转移；仅旧任务会在完成后从「云下载」兜底转移。需要 Cookie 直连模式。</li>
                      <li><b>管线 D · 本地 strm 媒体库：</b>跟在管线 C 之后，115 离线完成后自动生成 strm 文件到 /strm（宿主机 jable-media-library/strm/），供 Emby/Infuse 扫描播放；需配置「服务访问地址」。关闭管线 D 不影响在线播放（点播放仍可 302 直连 115 CDN）。</li>
                    </ul>
                    <Typography.Title level={5}>常见问题</Typography.Title>
                    <ul>
                      <li>提示 115 未配置：到「115 登录」页签保存 Cookie 或扫码登录。</li>
                      <li>影片列表加载失败：检查「网络代理」页签的代理地址是否可用。</li>
                      <li>115 大文件播放失败：确认播放方式为 302 直连。</li>
                      <li>路径类设置修改后需点右上角「保存设置」才会生效。</li>
                    </ul>
                  </Typography> },
                  { key: 'maintenance', label: '数据维护', children: <MaintenancePanel /> },
                  { key: 'logs', label: '日志中心', children: <LogCenterPage initialModule={logModulePreset} /> },
                  { key: 'license', label: '授权管理', children: <LicenseManager /> }
                ]} />
              </Form>
            </Card>
            {settingsTab === '115' && <Cloud115SigninPanel status={signinStatus} loading={signinLoading} onRefresh={loadSigninStatus} onRun={run115Signin} />}
          </>}
        </Layout.Content>
      </Layout>
    </Layout>
    <Drawer className="detail-drawer" open={!!selected} title="影片详情" width={720} onClose={() => setSelected(null)}
      footer={<Space wrap><Button icon={<SearchOutlined />} loading={captureLoading} onClick={captureMedia}>抓取 M3U8</Button><Button icon={<CloudServerOutlined />} loading={cloudLoading} onClick={addCloudFromDetail}>离线到 115</Button><Button type="primary" loading={localLoading} icon={<FolderOpenOutlined />} onClick={addLocal}>本地下载入库</Button></Space>}>
      {selected && <DetailPanel film={selected} detail={filmDetail} detailLoading={detailLoading} captured={captured} localTasks={currentLocalTasks} cloudTasks={currentCloudTasks} onCloudUrl={addCloudUrl} cloudLoading={cloudLoading} onDeleteCloud={deleteCloud} onPlayStrm={playStrm} onRefreshCloud={refreshCloudNow} cloudRefreshing={cloudRefreshing} onPlayPickcode={playPickcode} />}
    </Drawer>
    <Modal className="player-modal" open={!!playingLocal} title={playingLocal?.name || '正在播放'} width="min(1040px, 96vw)" footer={null} onCancel={() => setPlayingLocal(null)} destroyOnClose centered>
      {playingLocal && <video className="player-video" key={playingLocal.path} src={`/api/media/play?path=${encodeURIComponent(playingLocal.path)}`} controls autoPlay playsInline preload="metadata" controlsList="nodownload" />}
    </Modal>
    <Modal className="form-modal" open={cloudOpen} title="新建 115 离线任务" okText="提交到 115" confirmLoading={cloudLoading} onCancel={() => setCloudOpen(false)} onOk={addCloud}>
      <Form form={cloudForm} layout="vertical"><Form.Item name="source_url" label="磁力链接或下载地址" rules={[{ required: true, message: '请输入磁力链接或 HTTP 地址' }]}><Input.TextArea rows={4} placeholder="magnet:?xt=urn:btih:... 或 https://..." /></Form.Item></Form>
    </Modal>
    <Modal className="player-modal" open={!!playingStrm} title={playingStrm ? `${playingStrm.catalog || ''} ${playingStrm.title}`.trim() : '正在播放'} width="min(1040px, 96vw)" footer={null} onCancel={() => setPlayingStrm(null)} destroyOnClose centered>
      {playingStrm && <video className="player-video" key={playingStrm.id} src={`/api/115/stream/${playingStrm.id}`} controls autoPlay playsInline preload="metadata" controlsList="nodownload" />}
      {playingStrm?.file_path && <Typography.Text type="secondary">115 网盘位置：{playingStrm.file_path}</Typography.Text>}
    </Modal>
    <Modal className="player-modal" open={!!playingPickcode} title={playingPickcode?.title || '正在播放'} width="min(1040px, 96vw)" footer={null} onCancel={() => setPlayingPickcode(null)} destroyOnClose centered>
      {playingPickcode && <>
        {playLoading ? (
          <div style={{ textAlign: 'center', padding: '120px 0', color: '#999' }}>
            <Spin size="large" tip="正在获取 115 直链..." />
          </div>
        ) : playError ? (
          <Alert type="error" showIcon message="播放失败" description={playError} style={{ margin: '80px 20px' }} />
        ) : (
          <video className="player-video" key={playingPickcode.pickcode} src={`/api/115/play/${playingPickcode.pickcode}`} controls autoPlay playsInline preload="metadata" controlsList="nodownload" />
        )}
        <Typography.Text type="secondary">来源：115 网盘直链播放（pickcode: {playingPickcode.pickcode}）</Typography.Text>
      </>}
    </Modal>
    <Modal className="form-modal" open={manualScrapeOpen} title="手动刮削 strm / 视频文件" okText="开始刮削" confirmLoading={manualScrapeLoading} onCancel={() => { setManualScrapeOpen(false); manualScrapeForm.resetFields() }} onOk={submitManualScrape} width={560}>
      <Alert type="info" showIcon message="刮削说明" description="选择包含 strm 或视频文件的目录（会递归扫描），或直接指定文件路径。系统将从文件名自动识别番号并抓取 metadata。" style={{ marginBottom: 12 }} />
      <Form form={manualScrapeForm} layout="vertical">
        <Form.Item name="paths" label="目录或文件路径" rules={[{ required: true, message: '请选择目录或文件' }]}>
          <DirTreeSelect basePath="/media" placeholder="选择 /media 下的目录（也可手动输入完整路径）" />
        </Form.Item>
      </Form>
    </Modal>
  </>
}

function DetailPanel({
  film, detail, detailLoading, captured, localTasks, cloudTasks, onCloudUrl, cloudLoading, onDeleteCloud, onPlayStrm, onRefreshCloud, cloudRefreshing, onPlayPickcode
}: {
  film: Film; detail: FilmDetail | null; detailLoading: boolean; captured: Capture | null;
  localTasks: DownloadTask[]; cloudTasks: CloudTask[]; onCloudUrl: (sourceUrl: string, title?: string) => void; cloudLoading: boolean; onDeleteCloud: (id: string) => void; onPlayStrm?: (item: StrmItem) => void; onRefreshCloud?: () => void; cloudRefreshing?: boolean; onPlayPickcode?: (pickcode: string, title: string) => void
}) {
  const samples = detail?.samples || []
  const magnets = detail?.magnets || []
  // 样张/封面走后端代理缓存（/tmp/img-cache 磁盘缓存），避免直连被墙的 jable CDN
  const proxied = (u: string) => u ? `/api/proxy-image?url=${encodeURIComponent(u)}` : ''
  return <Space direction="vertical" size={18} className="detail-panel">
    <Image className="detail-cover" src={proxied(detail?.cover_url || film.image_url)} fallback="" preview={false} />
    <Typography.Title level={4}>{detail?.title || film.title}</Typography.Title>
    <Descriptions column={1} size="small">
      <Descriptions.Item label="番号">{detail?.catalog || film.catalog || '未识别'}</Descriptions.Item>
      <Descriptions.Item label="时长">{film.duration || '未知'}</Descriptions.Item>
      <Descriptions.Item label="详情链接"><Typography.Link copyable>{film.detail_url}</Typography.Link></Descriptions.Item>
      {captured && <Descriptions.Item label="M3U8"><Typography.Text copyable className="media-url">{captured.media_url}</Typography.Text></Descriptions.Item>}
    </Descriptions>
    <Spin spinning={detailLoading}>
      <Card size="small" title={`样张预览${samples.length ? `（${samples.length}）` : ''}`}>
        {samples.length ? <Image.PreviewGroup><div className="sample-strip">{samples.map((sample, index) => <Image key={`${sample}-${index}`} src={proxied(sample)} fallback="" />)}</div></Image.PreviewGroup> : <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="暂未读取到样张" />}
      </Card>
      <Card size="small" title={`磁力链接${magnets.length ? `（${magnets.length}）` : ''}`} className="magnet-card">
        {magnets.length ? <List dataSource={magnets} renderItem={(magnet, index) => <List.Item actions={[<Button key="copy" size="small" icon={<CopyOutlined />} onClick={() => navigator.clipboard.writeText(magnet.url).then(() => message.success('磁力链接已复制'))}>复制链接</Button>, <Button key="cloud" size="small" type="primary" loading={cloudLoading} icon={<CloudServerOutlined />} onClick={() => onCloudUrl(magnet.url, magnet.name || film.title)}>离线到 115</Button>]}><List.Item.Meta title={<Space wrap><Typography.Text strong>{magnet.name || `磁力链接 ${index + 1}`}</Typography.Text>{magnet.size && <Tag color="blue">{magnet.size}</Tag>}{magnet.files && <Tag>{magnet.files}</Tag>}</Space>} description={<Typography.Text type="secondary" ellipsis copyable>{magnet.url}</Typography.Text>} /></List.Item>} /> : <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="暂未读取到磁力链接" />}
      </Card>
    </Spin>
    <Card size="small" title="本地结果"><TaskMiniList tasks={localTasks} /></Card>
    <CloudMiniList tasks={cloudTasks} onDelete={onDeleteCloud} onPlayStrm={onPlayStrm} onRefresh={onRefreshCloud} refreshing={cloudRefreshing} onPlayPickcode={onPlayPickcode} />
  </Space>
}

// 目录选择器:从 /api/dirs 异步加载目录树
function DirTreeSelect({ value, onChange, basePath = '/media', placeholder = '请选择目录（留空使用默认）' }: {
  value?: string; onChange?: (v: string) => void; basePath?: string; placeholder?: string;
}) {
  const [options, setOptions] = useState<any[]>([])
  const loadData = async (selectedOptions: any[]) => {
    const targetOption = selectedOptions[selectedOptions.length - 1]
    try {
      const path = targetOption?.value || basePath
      const items: { path: string; name: string; type: string }[] = await api(`/api/dirs?base=${encodeURIComponent(path)}&recursive=0`)
      const children = items.filter(i => i.type === 'dir').map(i => ({
        label: i.name, value: i.path, isLeaf: false,
      }))
      targetOption.children = children
      setOptions([...options])
    } catch { /* ignore */ }
  }
  useEffect(() => {
    (async () => {
      try {
        const items: { path: string; name: string; type: string }[] = await api(`/api/dirs?base=${encodeURIComponent(basePath)}&recursive=0`)
        setOptions(items.filter(i => i.type === 'dir').map(i => ({ label: i.name, value: i.path, isLeaf: false })))
      } catch { /* ignore */ }
    })()
  }, [])
  const selectedValue = value ? (() => {
    // 尝试从 value 字符串反推 cascader 路径: 找到 value 对应的节点路径
    if (value === basePath) return [value]
    return [basePath, value.replace(basePath + '/', '')]
  })() : undefined
  return <Cascader
    style={{ width: '100%' }}
    value={selectedValue as any}
    options={options}
    loadData={loadData}
    changeOnSelect
    placeholder={placeholder}
    allowClear
    onChange={(v: any) => onChange?.(v ? v[v.length - 1] : '')}
  />
}

// 115 网盘目录选择器:从 /api/115/dirs 异步加载目录树，value 为 115 目录 cid
function Dir115TreeSelect({ value, onChange, onPathChange, placeholder = '选择 115 网盘中的目标目录' }: {
  value?: string; onChange?: (v: string) => void; onPathChange?: (path: string) => void; placeholder?: string;
}) {
  const [options, setOptions] = useState<any[]>([])
  const [loaded, setLoaded] = useState(false)
  const [error, setError] = useState('')
  const pathMap = useRef<Map<string, string>>(new Map())
  const loadRoot = async () => {
    setError('')
    try {
      const items: { cid: string; name: string; type: string }[] = await api('/api/115/dirs?cid=0')
      const rootChildren = items.filter(i => i.type === 'dir').map(i => {
        pathMap.current.set(i.cid, i.name)
        return { label: i.name, value: i.cid, isLeaf: false, path: i.name }
      })
      setOptions([{ label: '根目录', value: '0', isLeaf: false, path: '', children: rootChildren }])
      setLoaded(true)
      if (!rootChildren.length) setError('115 根目录没有读取到任何文件夹：请点「检测登录状态」确认 Cookie 有效，或重新扫码登录后点「重新加载」')
    } catch (e) {
      setLoaded(false)
      setError(e instanceof Error ? e.message : '115 目录加载失败')
    }
  }
  const loadData = async (selectedOptions: any[]) => {
    const targetOption = selectedOptions[selectedOptions.length - 1]
    const cid = targetOption.value
    if (cid === '0') { if (error) loadRoot(); return }
    try {
      const items: { cid: string; name: string; type: string }[] = await api(`/api/115/dirs?cid=${encodeURIComponent(cid)}`)
      const parentPath = targetOption.path || ''
      const children = items.filter(i => i.type === 'dir').map(i => {
        const fullPath = `${parentPath}/${i.name}`
        pathMap.current.set(i.cid, fullPath)
        return { label: i.name, value: i.cid, isLeaf: false, path: fullPath }
      })
      targetOption.children = children
      targetOption.isLeaf = !children.length
      setOptions([...options])
      if (!children.length) setError(`「${targetOption.label || targetOption.path || cid}」目录下没有子文件夹`)
    } catch (e) {
      setError(e instanceof Error ? e.message : '115 目录加载失败')
    }
  }
  useEffect(() => { loadRoot() }, [])
  return <>
    <Cascader
    style={{ width: '100%' }}
    value={value ? ['0', value] : undefined}
    options={options}
    loadData={loadData}
    changeOnSelect
    placeholder={loaded ? placeholder : '加载 115 目录...'}
    allowClear
    expandTrigger="hover"
    onChange={(v: any) => {
      const cid = v?.[v.length - 1] || ''
      onChange?.(cid)
      onPathChange?.(cid ? (pathMap.current.get(cid) || '') : '')
    }}
    />
    {error && <Alert type="warning" showIcon style={{ marginTop: 6 }} message={error} action={<Button size="small" icon={<ReloadOutlined />} onClick={loadRoot}>重新加载</Button>} />}
  </>
}

function Cloud115SigninPanel({ status, loading, onRefresh, onRun }: {
  status: SigninStatus | null; loading: boolean; onRefresh: () => void; onRun: () => void
}) {
  const [enabled, setEnabled] = useState(false)
  const [cron, setCron] = useState('0 8 * * *')
  const [retryCount, setRetryCount] = useState(2)
  const [retryInterval, setRetryInterval] = useState(60)
  const [saving, setSaving] = useState(false)
  useEffect(() => {
    if (!status) return
    setEnabled(!!status.enabled)
    setCron(status.cron || '0 8 * * *')
    setRetryCount(Number(status.retry_count ?? 2))
    setRetryInterval(Number(status.retry_interval ?? 60))
  }, [status?.enabled, status?.cron, status?.retry_count, status?.retry_interval])
  const save = async () => {
    setSaving(true)
    try {
      await api('/api/settings', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          cloud115_signin_enabled: enabled,
          cloud115_signin_cron: cron,
          cloud115_signin_retry_count: retryCount,
          cloud115_signin_retry_interval: retryInterval
        })
      })
      message.success('115 自动签到设置已保存')
      onRefresh()
    } catch (error) {
      message.error(error instanceof Error ? error.message : '保存失败')
    } finally {
      setSaving(false)
    }
  }
  const recentLogs = status?.logs?.slice(0, 5) || []
  return <Card size="small" title={<Space>115 自动签到{enabled ? <Tag color="success">已开启</Tag> : <Tag>未开启</Tag>}</Space>} style={{ marginTop: 16 }}>
    <Alert type="info" showIcon message="需要 Cookie 直连模式" description="扫码登录或填写 115 Cookie 后可用。文件/目录登录成功不代表签到接口一定可用；系统会自动尝试 Android、iOS、网页版签到接口。cron 为五段格式：分钟 小时 日期 月份 星期，例如 0 8 * * * 表示每天 08:00。失败重试过程会写入日志中心。" style={{ marginBottom: 14 }} />
    <Space wrap align="start" size={12}>
      <Switch checked={enabled} onChange={setEnabled} checkedChildren="自动签到" unCheckedChildren="关闭" />
      <Input value={cron} onChange={e => setCron(e.target.value)} placeholder="0 8 * * *" style={{ width: 180 }} />
      <InputNumber min={0} max={10} value={retryCount} onChange={value => setRetryCount(Number(value ?? 0))} addonBefore="失败重试" addonAfter="次" style={{ width: 160 }} />
      <InputNumber min={10} max={86400} value={retryInterval} onChange={value => setRetryInterval(Number(value ?? 60))} addonBefore="间隔" addonAfter="秒" style={{ width: 170 }} />
      <Button icon={<SettingOutlined />} loading={saving} onClick={save}>保存签到设置</Button>
      <Button type="primary" icon={<CheckCircleOutlined />} loading={loading} onClick={onRun}>立即签到</Button>
      <Button icon={<ReloadOutlined />} onClick={onRefresh}>刷新记录</Button>
      <Button icon={<FileTextOutlined />} onClick={() => window.dispatchEvent(new CustomEvent('jable-open-log-center', { detail: { module: '115' } }))}>更多日志</Button>
    </Space>
    <Divider orientation="left" plain>最近 5 条签到记录</Divider>
    {recentLogs.length ? <List size="small" dataSource={recentLogs} renderItem={log => <List.Item>
      <List.Item.Meta
        title={<Space wrap><Tag color={log.state === 'success' ? 'success' : 'error'}>{log.state === 'success' ? '成功' : '失败'}</Tag><Typography.Text>{log.message}</Typography.Text>{log.reward && <Tag color="blue">{log.reward}</Tag>}</Space>}
        description={log.created_at}
      />
    </List.Item>} /> : <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="暂无签到记录" />}
    <Typography.Text type="secondary">这里只展示最近 5 条；每次失败重试过程、接口返回和更多历史请在日志中心按模块 115 查看。</Typography.Text>
  </Card>
}

// 路径配置:四条管线各一张卡片(内容展开),每张卡内的「配置说明」默认折叠
type StrmDiagCheck = { key: string; level: 'ok' | 'warn' | 'error'; title: string; detail: string; hint: string }
type StrmDiagResult = {
  checks: StrmDiagCheck[]
  stats: { enabled: boolean; base_url: string; base_url_reachable: boolean; completed: number; recognized: number; missing: number; strm_items: number }
  missing_tasks: { id: string; title: string; finished_at: string }[]
  recent_logs: { created_at: string; level: string; message: string }[]
  deep: { catalog: string; attempts: { source: string; ok: boolean; detail: string }[] } | null
}

// 管线 D 自检：逐步检查「115 离线完成 → 生成 strm → 刮削入库」链路，并支持一键补跑未入库任务
function StrmDiagnosePanel() {
  const [loading, setLoading] = useState<'quick' | 'deep' | null>(null)
  const [result, setResult] = useState<StrmDiagResult | null>(null)
  const [repairing, setRepairing] = useState(false)
  const run = async (deep: boolean) => {
    setLoading(deep ? 'deep' : 'quick')
    try {
      setResult(await api<StrmDiagResult>(`/api/strm/diagnose${deep ? '?deep=1' : ''}`))
    } catch (e) {
      message.error(e instanceof Error ? e.message : '检测失败')
    } finally {
      setLoading(null)
    }
  }
  const repair = async () => {
    setRepairing(true)
    try {
      const reply = await api<{ repaired: { id: string; title: string }[]; skipped: { id: string; title: string; reason: string }[] }>('/api/strm/diagnose/repair', { method: 'POST' })
      message.success(`补跑完成：新入库 ${reply.repaired.length} 个，跳过 ${reply.skipped.length} 个`)
      await run(false)
    } catch (e) {
      message.error(e instanceof Error ? e.message : '补跑失败')
    } finally {
      setRepairing(false)
    }
  }
  const icon = (level: string) => level === 'ok'
    ? <CheckCircleOutlined style={{ color: '#52c41a' }} />
    : level === 'warn' ? <WarningOutlined style={{ color: '#faad14' }} /> : <CloseCircleOutlined style={{ color: '#ff4d4f' }} />
  return <div>
    <Divider orientation="left" plain>管线 D 自检（检测入库 / 刮削哪里出问题）</Divider>
    <Space wrap style={{ marginBottom: 12 }}>
      <Button icon={<SearchOutlined />} loading={loading === 'quick'} onClick={() => run(false)}>开始检测</Button>
      <Button icon={<ThunderboltOutlined />} loading={loading === 'deep'} onClick={() => run(true)}>深度检测（实测刮削）</Button>
      <Button icon={<ToolOutlined />} loading={repairing} onClick={repair}>一键补跑未入库任务</Button>
    </Space>
    {result && <div className="strm-diag-result">
      {result.checks.map(check => (
        <div key={check.key} className="strm-diag-check">
          <span className="strm-diag-icon">{icon(check.level)}</span>
          <div className="strm-diag-body">
            <Typography.Text strong={check.level !== 'ok'}>{check.title}</Typography.Text>
            {check.detail && <div><Typography.Text type="secondary">{check.detail}</Typography.Text></div>}
            {check.hint && <div><Typography.Text type="warning">{check.hint}</Typography.Text></div>}
          </div>
        </div>
      ))}
      {result.deep && <Alert style={{ marginTop: 8 }} type={result.deep.attempts.some(a => a.ok) ? 'success' : 'error'} showIcon
        message={result.deep.catalog ? `实测刮削番号：${result.deep.catalog}` : '实测刮削'}
        description={<ul style={{ margin: 0, paddingLeft: 18 }}>{result.deep.attempts.map((a, i) => <li key={i}>{a.source}：{a.detail}</li>)}</ul>} />}
      {result.recent_logs.length > 0 && <Collapse ghost size="small" className="pipe-notes" items={[{
        key: 'logs', label: <Typography.Text type="secondary">最近 10 条 strm 日志</Typography.Text>,
        children: result.recent_logs.map((log, i) => <div key={i}><Typography.Text type="secondary">{log.created_at}</Typography.Text> <Typography.Text>{log.message}</Typography.Text></div>)
      }]} />}
    </div>}
  </div>
}

function PathPipelineConfig({ settingsForm }: { settingsForm: any }) {
  const watchEnabled = Form.useWatch('watch_enabled', settingsForm)
  const aScrape = Form.useWatch('local_scrape_enabled', settingsForm)
  const aTransfer = Form.useWatch('local_transfer_enabled', settingsForm)
  const bScrape = Form.useWatch('manual_scrape_enabled', settingsForm)
  const bTransfer = Form.useWatch('manual_transfer_enabled', settingsForm)
  const cTransfer = Form.useWatch('cloud_transfer_enabled', settingsForm)
  const dStrm = Form.useWatch('auto_strm_enabled', settingsForm)
  const cloudTransferPath = Form.useWatch('cloud_transfer_path', settingsForm)
  const stateTag = (on: unknown, onText: string) => <Tag color={on ? 'processing' : 'default'}>{on ? onText : '未启用'}</Tag>
  // 卡片内默认折叠的说明块
  const notes = (text: string) => (
    <Collapse ghost size="small" className="pipe-notes" items={[{ key: 'note', label: <Typography.Text type="secondary">配置说明</Typography.Text>, children: <Alert type="info" showIcon message={text} style={{ marginBottom: 8 }} /> }]} />
  )
  return <>
    <Alert type="info" showIcon message="本地可选目录均来自容器 /media 挂载点（对应 compose.yaml 的宿主机路径）；115 相关目录直接在 115 网盘中选择。" style={{ marginBottom: 14 }} />
    <Card size="small" title={<Space wrap>管线 A：本地下载{stateTag(aScrape, '刮削开')}{aScrape && aTransfer ? <Tag color="success">自动转移</Tag> : null}</Space>} className="pipe-card">
      {notes('触发：影片详情页「本地下载入库」按钮。流向：Jable 下载 → 刮削（封面/nfo/演员）→ 转移到本地目录（默认 /media/演员/番号/）。')}
      <Form.Item name="local_scrape_enabled" valuePropName="checked" label="刮削总开关" tooltip="关闭后该管线只下载，不抓取 metadata">
        <Switch checkedChildren="开启刮削" unCheckedChildren="关闭刮削" />
      </Form.Item>
      {aScrape && <Form.Item name="local_transfer_enabled" valuePropName="checked" label="刮削后转移" tooltip="关闭后只刮削 metadata，文件留在原位置">
        <Switch checkedChildren="转移到指定目录" unCheckedChildren="留在原地" />
      </Form.Item>}
      {aScrape && aTransfer && <Form.Item name="local_transfer_path" label="本地下载刮削后转移到">
        <DirTreeSelect basePath="/media" placeholder="使用默认 /media/演员/番号/" />
      </Form.Item>}
    </Card>
    <Card size="small" title={<Space wrap>管线 B：手动刮削（strm）{stateTag(bScrape, '刮削开')}{bScrape && bTransfer ? <Tag color="success">自动转移</Tag> : null}{watchEnabled ? <Tag color="geekblue">监控中</Tag> : null}</Space>} className="pipe-card">
      {notes('触发：详情页「手动刮削 strm」按钮、Watch Folder 监控发现新文件。流向：整理已有文件 → 刮削 → 转移到本地目录（默认 /media/演员/番号/）。')}
      <Form.Item name="manual_scrape_enabled" valuePropName="checked" label="刮削总开关" tooltip="关闭后该管线只移动，不抓取 metadata">
        <Switch checkedChildren="开启刮削" unCheckedChildren="关闭刮削" />
      </Form.Item>
      {bScrape && <Form.Item name="manual_transfer_enabled" valuePropName="checked" label="刮削后转移" tooltip="关闭后只刮削 metadata，文件留在原位置">
        <Switch checkedChildren="转移到指定目录" unCheckedChildren="留在原地" />
      </Form.Item>}
      {bScrape && bTransfer && <Form.Item name="manual_transfer_path" label="手动刮削后转移到">
        <DirTreeSelect basePath="/media" placeholder="使用默认 /media/演员/番号/" />
      </Form.Item>}
      <Divider orientation="left" plain>Watch Folder · 管线 B 的自动触发器</Divider>
      <Form.Item name="watch_enabled" valuePropName="checked" label="监控开关" tooltip="开启后后台定时扫描监控目录，发现新 strm/视频文件自动创建手动刮削任务">
        <Switch checkedChildren="开启监控" unCheckedChildren="关闭监控" />
      </Form.Item>
      {watchEnabled && <>
        <Form.Item name="watch_dir" label="监控目录" rules={[{ required: true, message: '请选择监控目录' }]} tooltip="选择一个目录，放入 strm 或视频文件后会自动触发刮削">
          <DirTreeSelect basePath="/media" placeholder="例如 /media/待刮削" />
        </Form.Item>
        <Form.Item name="watch_interval" label="扫描间隔(秒)" tooltip="每隔多少秒扫一次目录">
          <InputNumber min={3} max={300} style={{ width: 120 }} />
        </Form.Item>
        <Alert type="info" showIcon message="监控目录下的 .strm / .mp4 / .mkv / .ts 等文件会被自动发现并走「管线 B」刮削。文件正在写入时（mtime < 2 秒）会跳过，避免处理不完整的文件。" />
      </>}
    </Card>
    <Card size="small" title={<Space wrap>管线 C：115 网盘内秒转移{stateTag(cTransfer, '自动转移开')}</Space>} className="pipe-card">
      {notes('触发：提交离线任务时自动生效。行为：提交 115 离线时直接指定目标目录（115 的 wp_path_id），产物下载完成就直接落在目标目录，无需再转移。仅旧任务（提交时未配置目标目录的）会在完成后从「云下载」兜底转移。需要 Cookie 模式；115 离线失败的任务无法感知，会一直显示进行中，可自行删除。')}
      <Form.Item name="cloud_poll_interval" label="离线状态轮询间隔(秒)" tooltip="每隔多少秒查一次 115 离线产物，仅 cookie 模式生效">
        <InputNumber min={10} max={600} style={{ width: 160 }} />
      </Form.Item>
      <Form.Item name="cloud_transfer_enabled" valuePropName="checked" label="离线直接下载到目标目录" tooltip="开启后，提交离线任务时直接指定 115 目标目录，产物落位即完成，无需转移">
        <Switch checkedChildren="直落目标目录" unCheckedChildren="关闭" />
      </Form.Item>
      {cTransfer && <>
        <Form.Item name="cloud_transfer_cid" label="下载目标目录（115 网盘）" tooltip="在 115 网盘中选择离线文件的目标存放目录">
          <Dir115TreeSelect onPathChange={(path) => settingsForm.setFieldValue('cloud_transfer_path', path)} />
        </Form.Item>
        <Form.Item name="cloud_transfer_path" hidden><Input /></Form.Item>
        {cloudTransferPath && <Typography.Text type="secondary">当前目标：115 网盘 {cloudTransferPath}</Typography.Text>}
      </>}
    </Card>
    <Card size="small" title={<Space wrap>管线 D：本地 strm 媒体库{stateTag(dStrm, '自动 strm 开')}</Space>} className="pipe-card">
      {notes('触发：跟在管线 C 之后（115 离线完成后自动执行）。仅当你需要 Emby/Infuse 扫描本地 strm 目录时才需要开启。关闭管线 D 不影响 302 播放——115 离线完成后 cloud_tasks 会保存 pickcode，点播放直接 302 直连 115 CDN，无需 strm 文件。strm 文件固定落在宿主机 /volume2/docker/jable-media-library/strm/（compose 挂载为容器内 /strm）。')}
      <Form.Item name="service_base_url" label="服务访问地址" tooltip="写入 strm 文件的访问地址（仅管线 D 开启时需要），例如 http://192.168.2.50:8788">
        <Input placeholder={`例如 ${window.location.origin}`} />
      </Form.Item>
      <Form.Item name="auto_strm_enabled" valuePropName="checked" label="离线完成后自动生成 strm 并刮削" tooltip="仅当需要 Emby/Infuse 扫描本地 strm 目录时开启">
        <Switch checkedChildren="开启" unCheckedChildren="关闭" />
      </Form.Item>
      <StrmDiagnosePanel />
    </Card>
  </>
}

// 自动离线到 115：模式A=浏览详情触发, 模式B=定时追新扫描；规则过滤 + 单日限额
function AutoOfflineCard({ settingsForm }: { settingsForm: any }) {
  const enabled = Form.useWatch('auto_offline_enabled', settingsForm)
  const scheduleOn = Form.useWatch('auto_offline_schedule', settingsForm)
  const [logs, setLogs] = useState<any[]>([])
  const [todayCount, setTodayCount] = useState(0)
  const [runLoading, setRunLoading] = useState(false)
  const loadLogs = async () => {
    try {
      const data = await api<{ logs: any[]; today_count: number }>('/api/auto-offline')
      setLogs(data.logs || []); setTodayCount(data.today_count || 0)
    } catch { /* ignore */ }
  }
  useEffect(() => { if (enabled) loadLogs() }, [enabled])
  const runNow = async () => {
    setRunLoading(true)
    try {
      const reply = await api<{ message: string }>('/api/auto-offline/run', { method: 'POST' })
      message.success(reply.message || '扫描已启动')
      setTimeout(loadLogs, 8000)
    } catch (error) {
      message.warning(error instanceof Error ? error.message : '触发失败')
    } finally { setRunLoading(false) }
  }
  return <Card size="small" title={<Space wrap>自动离线到 115{enabled ? <Tag color="success">已开启</Tag> : <Tag>未开启</Tag>}{enabled && <Tag color="blue">今日 {todayCount} 部</Tag>}</Space>} className="pipe-card">
    <Form.Item name="auto_offline_enabled" valuePropName="checked" label="自动离线总开关" tooltip="开启后按规则自动把影片离线到 115，手动「离线到 115」按钮不受影响">
      <Switch checkedChildren="开启" unCheckedChildren="关闭" />
    </Form.Item>
    {enabled && <>
      <Form.Item name="auto_offline_browse" valuePropName="checked" label="模式 A：浏览触发" tooltip="打开影片详情、磁力抓取完成后自动匹配规则，命中即提交 115 离线">
        <Switch checkedChildren="开" unCheckedChildren="关" />
      </Form.Item>
      <Form.Item name="auto_offline_schedule" valuePropName="checked" label="模式 B：定时追新" tooltip="后台定时扫描 jable 最新列表，新影片匹配规则后自动离线">
        <Switch checkedChildren="开" unCheckedChildren="关" />
      </Form.Item>
      {scheduleOn && <>
        <Form.Item name="auto_offline_interval" label="检查间隔(小时)" tooltip="模式 B 每隔多少小时扫描一次最新列表">
          <InputNumber min={1} max={72} style={{ width: 140 }} />
        </Form.Item>
        <Form.Item name="auto_offline_pages" label="扫描页数" tooltip="每次扫描最新列表的前几页（每页约 24 部）">
          <InputNumber min={1} max={10} style={{ width: 140 }} />
        </Form.Item>
      </>}
      <Divider orientation="left" plain>筛选规则（防止空间爆炸）</Divider>
      <Form.Item name="auto_offline_whitelist" label="番号白名单" tooltip="逗号分隔的关键词，只自动离线番号包含其中之一的影片；留空 = 不限制">
        <Input placeholder="例如 SSIS,FC2,SONE（留空不限制）" />
      </Form.Item>
      <Form.Item name="auto_offline_min_duration" label="时长下限(分钟)" tooltip="低于该时长的跳过（过滤短片段）；0 = 不限制。模式 A 打开详情时若时长未知则不校验">
        <InputNumber min={0} max={600} style={{ width: 140 }} />
      </Form.Item>
      <Form.Item name="auto_offline_min_size" label="磁力体积下限(GB)" tooltip="自动选择体积最大的磁力，低于该体积跳过（过滤预告片/CM）；0 = 不限制">
        <InputNumber min={0} max={200} step={0.5} style={{ width: 140 }} />
      </Form.Item>
      <Form.Item name="auto_offline_daily_limit" label="单日上限(部)" tooltip="每日自动离线最多提交多少部，保护 115 离线配额与网盘空间">
        <InputNumber min={1} max={50} style={{ width: 140 }} />
      </Form.Item>
      <Space wrap>
        <Button icon={<CloudServerOutlined />} loading={runLoading} onClick={runNow}>手动扫描一轮</Button>
        <Button onClick={loadLogs}>刷新记录</Button>
      </Space>
      <Divider orientation="left" plain>执行记录（最近 50 条）</Divider>
      {logs.length ? <List size="small" dataSource={logs} renderItem={(log: any) => <List.Item><List.Item.Meta title={<Space wrap><Typography.Text strong>{log.catalog || '未知番号'}</Typography.Text><Tag color={log.state === 'submitted' ? 'success' : log.state === 'failed' ? 'error' : 'default'}>{log.state === 'submitted' ? '已提交' : log.state === 'failed' ? '失败' : '跳过'}</Tag><Tag>{log.mode === 'browse' ? '浏览触发' : '定时追新'}</Tag>{log.magnet_size && <Tag color="blue">{log.magnet_size}</Tag>}</Space>} description={<Typography.Text type="secondary" ellipsis>{log.message || ''} · {log.created_at}</Typography.Text>} /></List.Item>} /> : <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="暂无执行记录" />}
    </>}
  </Card>
}

function TaskMiniList({ tasks }: { tasks: DownloadTask[] }) {
  if (!tasks.length) return <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="暂无本地任务" />
  return <List size="small" dataSource={tasks} renderItem={task => <List.Item actions={[task.state === 'completed' ? <Button size="small" icon={<PlayCircleOutlined />} onClick={() => window.open(`/api/tasks/${task.id}/play`, '_blank')}>播放</Button> : null].filter(Boolean)}><List.Item.Meta avatar={task.cover_url ? <Image width={46} height={32} src={task.cover_url} preview={false} /> : <VideoCameraOutlined className="file-icon" />} title={<Space><Tag color={task.state === 'completed' ? 'success' : task.state === 'failed' ? 'error' : 'processing'}>{task.state}</Tag><Typography.Text>{task.phase}</Typography.Text></Space>} description={<Progress percent={Math.round((task.progress || 0) * 100)} size="small" />} /></List.Item>} />
}

function CloudMiniList({ tasks, onDelete, onPlayStrm, onRefresh, refreshing, onPlayPickcode }: { tasks: CloudTask[]; onDelete?: (id: string) => void; onPlayStrm?: (item: StrmItem) => void; onRefresh?: () => void; refreshing?: boolean; onPlayPickcode?: (pickcode: string, title: string) => void }) {
  const playBtn = (task: CloudTask) => {
    if (task.pickcode) return <Button size="small" type="primary" icon={<PlayCircleOutlined />} onClick={() => onPlayPickcode?.(task.pickcode!, `${task.catalog || ''} ${task.title}`.trim())}>播放</Button>
    if (task.strm_id && onPlayStrm) return <Button size="small" type="primary" icon={<PlayCircleOutlined />} onClick={() => onPlayStrm({ id: task.strm_id!, catalog: task.catalog, title: task.title, file_path: task.file_path, created_at: task.created_at })}>播放</Button>
    return null
  }
  return <Card size="small" title={<Space>115 结果<Tag color="blue">{tasks.length}</Tag></Space>}
    extra={onRefresh ? <Button size="small" icon={<ReloadOutlined />} loading={refreshing} onClick={onRefresh}>刷新</Button> : null}>
    {!tasks.length ? <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="暂无 115 任务" /> :
      <List size="small" dataSource={tasks} renderItem={task => <List.Item actions={[playBtn(task), onDelete ? <Button key="del" size="small" danger type="text" onClick={() => onDelete(task.id)}>删除</Button> : null].filter(Boolean)}><List.Item.Meta title={<Space><Tag color={task.state === 'completed' ? 'success' : task.state === 'failed' ? 'error' : 'processing'}>{task.state}</Tag><Typography.Text>{task.message}</Typography.Text></Space>} description={<>{task.file_path && <div>云盘位置：{task.file_path}</div>}{task.created_at}</>} /></List.Item>} />}
  </Card>
}

function FilmGrid({ films, onSelect }: { films: Film[]; onSelect: (film: Film) => void }) {
  return films.length ? <div className="film-grid">{films.map(film => <Card key={film.detail_url} hoverable className="film-card" cover={<Image preview={false} src={film.image_url ? `/api/proxy-image?url=${encodeURIComponent(film.image_url)}` : ''} fallback="" onClick={() => onSelect(film)} />} actions={[<Button key="open" type="link" icon={<PlayCircleOutlined />} onClick={() => onSelect(film)}>详情与下载</Button>]}><Card.Meta title={film.catalog || '未识别番号'} description={<Typography.Paragraph ellipsis={{ rows: 2 }}>{film.title}</Typography.Paragraph>} /><div className="film-duration">{film.duration}</div></Card>)}</div> : <Empty description="没有读取到影片，请在服务设置中配置代理后刷新" />
}

// 封面缩略图：hover 时放大预览（portal 到 body，避免被表格滚动容器裁剪）
function PosterThumb({ src, catalog, width = 56, ratio = 0.66 }: { src: string; catalog?: string; width?: number; ratio?: number }) {
  const [zoom, setZoom] = useState<{ x: number; y: number } | null>(null)
  const ref = useRef<HTMLDivElement>(null)
  if (!src) return <VideoCameraOutlined className="file-icon" />
  const height = Math.round(width / ratio)
  return <div ref={ref} style={{ display: 'inline-block', lineHeight: 0 }}
    onMouseEnter={event => { const rect = (event.currentTarget as HTMLElement).getBoundingClientRect(); setZoom({ x: rect.left + rect.width / 2, y: rect.top }) }}
    onMouseLeave={() => setZoom(null)}>
    <img src={src} alt={catalog || ''} loading="lazy"
      style={{ width, height, objectFit: 'cover', borderRadius: 6, background: '#e7eef8', cursor: 'zoom-in' }} />
    {zoom && createPortal(<img src={src} alt={catalog || ''}
      style={{ position: 'fixed', left: zoom.x, top: zoom.y - 10, transform: 'translate(-50%, -100%) scale(1)', width: 240, aspectRatio: `${ratio}`, objectFit: 'cover', borderRadius: 10, boxShadow: '0 12px 40px rgba(0,0,0,.35)', zIndex: 3000, pointerEvents: 'none', background: '#000' }} />, document.body)}
  </div>
}

type TaskRow = {
  key: string; source: 'local' | 'cloud' | 'huangguo'; catalog: string; title: string; cover_url?: string
  state: string; created_at: string; local?: DownloadTask; cloud?: CloudTask; hg?: HgEpisodeTask
}

type MaintStats = {
  series: number; episodes: { total?: number; downloaded?: number; failed?: number; active?: number }
  db_size: number; media_size: number; work_size: number; img_cache_size: number
  backups: { name: string; size: number; mtime: string }[]
}
type VerifyReply = {
  checked: number; fixed: Record<string, number>; missing_count: number
  missing: { title: string; ep: number; message: string }[]
}

type HgScanState = {
  running: boolean; phase: string; tabs: number; tabs_done: number; pages: number; pages_done: number; page: number
  found: number; added: number; skipped: number; failed: number; queued_episodes: number
  current: string; started_at: string; finished_at: string; error: string
}

function MaintenancePanel() {
  const [stats, setStats] = useState<MaintStats | null>(null)
  const [busy, setBusy] = useState('')
  const [verify, setVerify] = useState<VerifyReply | null>(null)
  const load = async () => {
    try { setStats(await api<MaintStats>('/api/hg/maintenance/stats')) } catch { /* ignore */ }
  }
  useEffect(() => { load() }, [])
  const fmtSize = (n?: number) => !n ? '0 KB' : n >= 1024 ** 3 ? `${(n / 1024 ** 3).toFixed(2)} GB` : n >= 1024 ** 2 ? `${(n / 1024 ** 2).toFixed(1)} MB` : `${(n / 1024).toFixed(0)} KB`
  const doBackup = async () => {
    setBusy('backup')
    try {
      const r = await api<{ name: string; removed: number }>('/api/hg/maintenance/backup', { method: 'POST' })
      message.success(`备份完成：${r.name}${r.removed ? `（清理旧备份 ${r.removed} 份）` : ''}`)
      await load()
    } catch (error) { message.error(error instanceof Error ? error.message : '备份失败') } finally { setBusy('') }
  }
  const doCleanup = () => Modal.confirm({
    title: '清理临时文件？',
    content: '将删除下载临时目录中 6 小时前的残留分片/临时文件，以及超过 24 小时的图片失败标记缓存；正在进行的下载不受影响。',
    okText: '开始清理',
    onOk: async () => {
      setBusy('cleanup')
      try {
        const r = await api<{ removed: number; freed: number; fail_removed: number }>('/api/hg/maintenance/cleanup', { method: 'POST' })
        message.success(`已清理 ${r.removed} 项，释放 ${(r.freed / 1024 / 1024).toFixed(1)} MB${r.fail_removed ? `，过期失败缓存 ${r.fail_removed} 个` : ''}`)
        await load()
      } catch (error) { message.error(error instanceof Error ? error.message : '清理失败') } finally { setBusy('') }
    }
  })
  const doVerify = () => Modal.confirm({
    title: '执行全库完整性校验？',
    content: '对比数据库与磁盘，自动补齐缺失的 tvshow.nfo / metadata.json / 每集 nfo / poster.jpg / strm；视频文件缺失仅报告不会自动重下。',
    okText: '开始校验',
    onOk: async () => {
      setBusy('verify')
      try {
        const r = await api<VerifyReply>('/api/hg/verify-library', { method: 'POST' })
        setVerify(r)
        message.success(`校验完成：${r.checked} 部剧集，补齐 ${Object.values(r.fixed).reduce((a, b) => a + b, 0)} 项`)
      } catch (error) { message.error(error instanceof Error ? error.message : '校验失败') } finally { setBusy('') }
    }
  })
  const statItems = stats ? [
    { key: 'series', label: '追剧库短剧', children: `${stats.series} 部` },
    { key: 'eps', label: '剧集集数', children: `共 ${stats.episodes?.total || 0} 集（已下 ${stats.episodes?.downloaded || 0} / 失败 ${stats.episodes?.failed || 0} / 进行中 ${stats.episodes?.active || 0}）` },
    { key: 'db', label: '数据库体积', children: fmtSize(stats.db_size) },
    { key: 'media', label: '黄果本地媒体', children: fmtSize(stats.media_size) },
    { key: 'work', label: '下载临时目录', children: fmtSize(stats.work_size) },
    { key: 'img', label: '封面缓存', children: fmtSize(stats.img_cache_size) },
  ] : []
  return <Space direction="vertical" size={16} style={{ width: '100%' }}>
    <Card size="small" title={<Space size={6}><Statistic title="短剧" value={stats?.series || 0} valueStyle={{ fontSize: 18 }} /><Statistic title="集数" value={stats?.episodes?.total || 0} valueStyle={{ fontSize: 18 }} /></Space>} extra={<Button icon={<ReloadOutlined />} onClick={load}>刷新统计</Button>}>
      <Descriptions size="small" bordered column={{ xs: 1, sm: 2, md: 3 }} items={statItems} />
    </Card>
    <Card size="small" title="数据库备份" extra={<Button type="primary" size="small" icon={<DatabaseOutlined />} loading={busy === 'backup'} onClick={doBackup}>立即备份</Button>}>
      <Typography.Text type="secondary">在线备份 SQLite 数据库到 /data/backups（自动保留最近 10 份）。备份不包含已下载的视频文件。</Typography.Text>
      {stats?.backups?.length ? <List size="small" style={{ marginTop: 8 }} dataSource={stats.backups.slice(0, 5)} renderItem={(item: { name: string; size: number; mtime: string }) => (
        <List.Item><Typography.Text ellipsis style={{ maxWidth: '60%' }}>{item.name}</Typography.Text><Typography.Text type="secondary">{fmtSize(item.size)} · {item.mtime}</Typography.Text></List.Item>
      )} /> : <Typography.Paragraph type="secondary" style={{ marginTop: 8 }}>暂无备份</Typography.Paragraph>}
    </Card>
    <Card size="small" title="临时文件清理" extra={<Button size="small" danger loading={busy === 'cleanup'} onClick={doCleanup}>开始清理</Button>}>
      <Typography.Text type="secondary">当前下载临时目录占用 {fmtSize(stats?.work_size)}。清理会删除 6 小时前的残留分片与临时文件（下载分片/.ts 等），以及 24 小时前的图片失败标记。</Typography.Text>
    </Card>
    <Card size="small" title="全库完整性校验" extra={<Button type="primary" size="small" icon={<ToolOutlined />} loading={busy === 'verify'} onClick={doVerify}>开始校验</Button>}>
      <Typography.Text type="secondary">对比数据库与磁盘：自动补齐缺失的 tvshow.nfo / metadata.json / 每集 nfo / poster.jpg / strm（已上传并删除源文件的集数也会补 strm）；视频文件缺失仅报告。</Typography.Text>
      {verify && <Alert style={{ marginTop: 8 }} type={verify.missing_count ? 'warning' : 'success'} showIcon
        message={`已校验 ${verify.checked} 部：补齐元数据 ${verify.fixed.metadata || 0} · nfo ${verify.fixed.nfo || 0} · 海报 ${verify.fixed.poster || 0} · strm ${verify.fixed.strm || 0}`}
        description={verify.missing_count ? <Typography.Paragraph style={{ marginBottom: 0 }}>发现 {verify.missing_count} 处文件缺失：{verify.missing.slice(0, 8).map(m => `${m.title}${m.ep ? ` 第${m.ep}集` : ''}`).join('、')}{verify.missing_count > 8 ? ' 等' : ''}</Typography.Paragraph> : undefined} />}
    </Card>
  </Space>
}

// ===== Apple TV 风格选集弹窗 + 黄果在线播放（未下载也能播） =====
type EpisodeChip = { key: string; label: string; hint?: string; disabled?: boolean }
type HgOnlineSeries = { id?: string; title: string; cover_url: string; detail_url?: string; episodes: { ep: number; play_url: string; locked: boolean; file_path?: string }[] }
type HgOnlineState = { open: boolean; loading: boolean; error: string; series: HgOnlineSeries | null; playing: { ep: number; url: string } | null }

function HlsVideo({ src, poster }: { src: string; poster?: string }) {
  const boxRef = useRef<HTMLDivElement>(null)
  const videoRef = useRef<HTMLVideoElement>(null)
  const [failed, setFailed] = useState('')
  const [full, setFull] = useState(false)
  useEffect(() => {
    const video = videoRef.current
    if (!video) return
    setFailed('')
    if (!src.includes('.m3u8')) {
      video.src = src
      return
    }
    // Safari 原生支持 HLS（含 AES-128），其余浏览器用 hls.js
    if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = src
      return
    }
    const hls = new Hls({ maxBufferLength: 24 })
    hls.loadSource(src)
    hls.attachMedia(video)
    hls.on(Hls.Events.ERROR, (_event, data) => {
      if (data.fatal) setFailed('视频加载失败，请关闭后重试或稍后再试')
    })
    return () => hls.destroy()
  }, [src])
  useEffect(() => {
    const onChange = () => setFull(!!document.fullscreenElement)
    document.addEventListener('fullscreenchange', onChange)
    return () => document.removeEventListener('fullscreenchange', onChange)
  }, [])
  const toggleFullscreen = () => {
    const box = boxRef.current
    const video = videoRef.current as HTMLVideoElement & { webkitEnterFullscreen?: () => void }
    if (!box) return
    if (document.fullscreenElement) { document.exitFullscreen(); return }
    if (box.requestFullscreen) box.requestFullscreen().catch(() => { video?.webkitEnterFullscreen?.() })
    else video?.webkitEnterFullscreen?.() // iPhone Safari 仅支持视频原生全屏
  }
  return <div ref={boxRef} className={full ? 'ep-player ep-full' : 'ep-player'}>
    <video ref={videoRef} className="player-video" controls autoPlay playsInline preload="metadata" controlsList="nodownload" poster={poster} />
    <button type="button" className="ep-fs-btn" title={full ? '退出全屏' : '全屏播放'} onClick={toggleFullscreen}>
      {full ? <FullscreenExitOutlined /> : <FullscreenOutlined />}
    </button>
    {failed && <div className="ep-video-error">{failed}</div>}
  </div>
}

function EpisodePickerModal({ open, loading, error, title, subtitle, cover, chips, activeKey, onSelect, onClose, player }:
  { open: boolean; loading?: boolean; error?: string; title?: string; subtitle?: string; cover?: string;
    chips: EpisodeChip[]; activeKey?: string; onSelect: (chip: EpisodeChip) => void; onClose: () => void;
    player?: React.ReactNode }) {
  const [full, setFull] = useState(false)
  const firstPlayable = chips.find(chip => !chip.disabled)
  return <Modal open={open} width={full ? '100vw' : 'min(1200px, 96vw)'} footer={null} onCancel={onClose}
    className={full ? 'ep-modal fullscreen' : 'ep-modal'} centered destroyOnClose title={null}>
    <Button className="ep-modal-fs-btn" type="text" size="small" title={full ? '退出全屏' : '全屏'}
      icon={full ? <FullscreenExitOutlined /> : <FullscreenOutlined />} onClick={() => setFull(value => !value)} />
    {loading ? <div className="ep-loading"><Spin size="large" /></div>
      : error ? <div className="ep-online-error"><Alert type="error" showIcon message="在线播放解析失败" description={error} /></div>
        : <>
          {player || <div className="ep-hero" style={cover ? { backgroundImage: `url("${cover}")` } : undefined}>
            <div className="ep-hero-shade" />
            <div className="ep-hero-body">
              <div className="ep-hero-poster">{cover ? <img src={cover} alt="" onError={event => { event.currentTarget.style.visibility = 'hidden' }} /> : <PlayCircleOutlined />}</div>
              <div className="ep-hero-info">
                <h3>{title}</h3>
                {subtitle && <div className="ep-hero-sub">{subtitle}</div>}
                {firstPlayable && <Button type="primary" size="large" icon={<PlayCircleOutlined />} onClick={() => onSelect(firstPlayable)}>播放</Button>}
              </div>
            </div>
          </div>}
          <div className="ep-chips-section">
            <div className="ep-chips-title">选集 <Typography.Text type="secondary" style={{ fontWeight: 400 }}>共 {chips.length} 集 · 点击分集立即播放</Typography.Text></div>
            {chips.length
              ? <div className="ep-chips">{chips.map(chip => (
                <button key={chip.key} type="button" disabled={chip.disabled} title={chip.disabled ? '该集暂不可播' : chip.label}
                  className={chip.key === activeKey ? 'ep-chip active' : 'ep-chip'} onClick={() => onSelect(chip)}>
                  <span>{chip.label}</span>{chip.hint && <small>{chip.hint}</small>}
                </button>))}</div>
              : <Empty description="没有可播放的分集" />}
          </div>
        </>}
  </Modal>
}

const epChipLabel = (title: string, index: number) => {
  const match = /第\s*(\d+)\s*[集话期]/.exec(title || '')
  return match ? String(parseInt(match[1], 10)) : String(index + 1)
}

function HuangguoPage({ onPlayLocal }: { onPlayLocal: (item: { name: string; path: string }) => void }) {
  const [series, setSeries] = useState<HgSeries[]>([])
  const [episodes, setEpisodes] = useState<HgEpisode[]>([])
  const [active, setActive] = useState<HgSeries | null>(null)
  const [catalogItems, setCatalogItems] = useState<HgCatalogItem[]>([])
  const [catalogTabs, setCatalogTabs] = useState<{ name: string; id: string }[]>([{ name: '首页', id: 'home' }])
  const [catalogTab, setCatalogTab] = useState('home')
  const [catalogPage, setCatalogPage] = useState(1)
  const [keyword, setKeyword] = useState('')
  const [catalogLoading, setCatalogLoading] = useState(false)
  const [url, setUrl] = useState('')
  const [loading, setLoading] = useState(false)
  const [adding, setAdding] = useState('')
  const [batchAdding, setBatchAdding] = useState(false)
  const [scan, setScan] = useState<HgScanState | null>(null)
  const [online, setOnline] = useState<HgOnlineState>({ open: false, loading: false, error: '', series: null, playing: null })
  const activeRef = useRef<HgSeries | null>(null)

  useEffect(() => { activeRef.current = active }, [active])

  const loadCatalog = async (nextTab = catalogTab, nextPage = catalogPage, q = keyword, force = false) => {
    setCatalogLoading(true)
    try {
      const params = new URLSearchParams({ tab: nextTab, page: String(nextPage) })
      if (q.trim()) params.set('q', q.trim())
      if (force) params.set('refresh', '1')
      const reply = await api<HgCatalogReply>(`/api/hg/catalog?${params.toString()}`)
      setCatalogItems(reply.items || [])
      setCatalogTabs(reply.tabs || catalogTabs)
      setCatalogTab(nextTab)
      setCatalogPage(nextPage)
    } catch (error) {
      message.error(error instanceof Error ? error.message : '黄果列表解析失败')
    } finally {
      setCatalogLoading(false)
    }
  }

  const loadSeries = async (silent = false) => {
    if (!silent) setLoading(true)
    try {
      const items = await api<HgSeries[]>('/api/hg/series')
      setSeries(items)
      if (activeRef.current) {
        const fresh = items.find(item => item.id === activeRef.current?.id) || null
        setActive(fresh)
        if (fresh) setEpisodes(await api<HgEpisode[]>(`/api/hg/series/${fresh.id}/episodes`))
      }
    } catch (error) {
      if (!silent) message.error(error instanceof Error ? error.message : '黄果短剧加载失败')
    } finally {
      if (!silent) setLoading(false)
    }
  }

  const loadEpisodes = async (item: HgSeries) => {
    setActive(item)
    setEpisodes(await api<HgEpisode[]>(`/api/hg/series/${item.id}/episodes`))
  }

  const closeOnline = () => setOnline({ open: false, loading: false, error: '', series: null, playing: null })
  const playOnlineEp = (epItem: { ep: number; play_url: string }) => {
    if (!epItem.play_url) { message.error('该集缺少播放地址'); return }
    setOnline(prev => ({ ...prev, playing: { ep: epItem.ep, url: `/api/hg/online-play?url=${encodeURIComponent(epItem.play_url)}&ep=${epItem.ep}` } }))
  }
  const openCatalogOnline = async (detailUrl: string) => {
    setOnline({ open: true, loading: true, error: '', series: null, playing: null })
    try {
      const data = await api<HgOnlineSeries>(`/api/hg/online-episodes?url=${encodeURIComponent(detailUrl)}`)
      setOnline({ open: true, loading: false, error: '', playing: null,
        series: { ...data, cover_url: data.cover_url ? (data.cover_url.startsWith('/api/') ? data.cover_url : `/api/proxy-image?url=${encodeURIComponent(data.cover_url)}`) : '' } })
    } catch (error) {
      setOnline({ open: true, loading: false, error: error instanceof Error ? error.message : '解析失败', series: null, playing: null })
    }
  }
  const openSeriesOnline = async (item: HgSeries, autoEp = 0) => {
    setOnline({ open: true, loading: true, error: '', series: null, playing: null })
    try {
      const list = await api<HgEpisode[]>(`/api/hg/series/${item.id}/episodes`)
      const mapped = list.map(entry => ({ ep: entry.ep, play_url: entry.play_url, locked: false, file_path: entry.file_path || '' }))
      const auto = autoEp ? mapped.find(entry => entry.ep === autoEp) : undefined
      setOnline({ open: true, loading: false, error: '', playing: auto && auto.play_url ? { ep: auto.ep, url: `/api/hg/online-play?url=${encodeURIComponent(auto.play_url)}&ep=${auto.ep}` } : null,
        series: { id: item.id, title: item.title, cover_url: `/api/hg/cover/${item.id}`, episodes: mapped } })
    } catch (error) {
      setOnline({ open: true, loading: false, error: error instanceof Error ? error.message : '解析失败', series: null, playing: null })
    }
  }

  useEffect(() => {
    loadSeries()
    loadCatalog('home', 1, '')
    const timer = window.setInterval(() => { loadSeries(true) }, 4000)
    return () => window.clearInterval(timer)
  }, [])

  const addSeries = async (inputUrl = url.trim()) => {
    if (!inputUrl.trim()) return
    setAdding(inputUrl.trim())
    try {
      const reply = await api<{ series: HgSeries; episodes: HgEpisode[]; existed?: boolean; queued?: number }>('/api/hg/series', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ url: inputUrl.trim() })
      })
      setUrl('')
      if (reply.existed) message.info('该短剧已在追剧库，已刷新剧集信息')
      else message.success(`短剧已入库，自动下载 ${reply.queued ?? 0} 集`)
      await loadSeries()
      setActive(reply.series); setEpisodes(reply.episodes || [])
    } catch (error) {
      message.error(error instanceof Error ? error.message : '添加失败')
    } finally {
      setAdding('')
    }
  }

  const runAction = async (path: string, okText: string) => {
    try {
      await api(path, { method: 'POST' })
      message.success(okText)
      await loadSeries()
    } catch (error) {
      message.error(error instanceof Error ? error.message : '操作失败')
    }
  }

  const setSeriesCompleted = async (item: HgSeries, completed: boolean) => {
    const commit = async () => {
      try {
        const reply = await api<{ queued: number }>(`/api/hg/series/${item.id}/complete`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ completed })
        })
        message.success(completed ? `已标记完结，${reply.queued || 0} 集等待上传` : '已恢复追更')
        await loadSeries()
      } catch (error) {
        message.error(error instanceof Error ? error.message : '操作失败')
      }
    }
    if (!completed) {
      await commit()
      return
    }
    Modal.confirm({
      title: '标记为全剧完结？',
      content: '标记后会停止自动追更，并把本地已下载、已刮削但未上传的集数加入 115 上传队列。',
      okText: '标记完结',
      cancelText: '取消',
      onOk: commit
    })
  }

  const deleteSeries = (item: HgSeries) => {
    Modal.confirm({
      title: `删除《${item.title}》？`,
      content: '将删除追剧记录、集数状态、持久化封面，以及本地已下载的视频文件（含刮削数据），不可恢复。',
      okText: '删除',
      okButtonProps: { danger: true },
      cancelText: '取消',
      async onOk() {
        try {
          const reply = await api<{ removed_dirs: number }>(`/api/hg/series/${item.id}`, { method: 'DELETE' })
          message.success(reply.removed_dirs ? `已删除该剧集，并清理 ${reply.removed_dirs} 个本地目录` : '已删除该剧集记录')
          if (activeRef.current?.id === item.id) { setActive(null); setEpisodes([]) }
          await loadSeries(true)
        } catch (error) {
          message.error(error instanceof Error ? error.message : '删除失败')
        }
      }
    })
  }

  const inLibrary = (id: string) => series.some(s => String(s.id) === String(id))
  const seriesById = useMemo(() => new Map(series.map(s => [String(s.id), s])), [series])
  const [seriesFilter, setSeriesFilter] = useState<'all' | 'downloading' | 'failed' | 'undownloaded' | 'done'>('all')
  const [seriesPage, setSeriesPage] = useState(1)
  const [epFilter, setEpFilter] = useState<'all' | 'queued' | 'running' | 'completed' | 'failed'>('all')
  const seriesCount = (pred: (item: HgSeries) => boolean) => series.filter(pred).length
  const filteredSeries = series.filter(item => {
    if (seriesFilter === 'downloading') return (item.active_episodes || []).length > 0
    if (seriesFilter === 'failed') return (item.failed_count || 0) > 0
    if (seriesFilter === 'undownloaded') return (item.downloaded_episodes || 0) === 0
    if (seriesFilter === 'done') return (item.total_episodes || 0) > 0 && (item.downloaded_episodes || 0) >= (item.total_episodes || 0)
    return true
  })
  const SERIES_PAGE_SIZE = 12
  const seriesPageClamped = Math.min(seriesPage, Math.max(1, Math.ceil(filteredSeries.length / SERIES_PAGE_SIZE)))
  const pagedSeries = filteredSeries.slice((seriesPageClamped - 1) * SERIES_PAGE_SIZE, seriesPageClamped * SERIES_PAGE_SIZE)
  // 顶部影片卡片状态标签：一眼看出哪些已入库/已下载，避免重复点击下载
  const catalogStatusTag = (id: string) => {
    const s = seriesById.get(String(id))
    if (!s) return null
    const total = s.total_episodes || 0
    const done = s.downloaded_episodes || 0
    if (total > 0 && done >= total) return <Tag color="success">已下载 {done}/{total}</Tag>
    if (done > 0) return <Tag color="processing">已下 {done}/{total}</Tag>
    return <Tag color="warning">已入库 · 未下载</Tag>
  }

  const seriesStatus = (item: HgSeries) => {
    const total = item.total_episodes || 0
    const done = item.downloaded_episodes || 0
    if (total > 0 && done >= total) return <Tag color="success">全部已下载</Tag>
    if (done > 0) return <Tag color="processing">已下 {done}/{total}</Tag>
    return <Tag color="warning">未下载</Tag>
  }

  const batchAddPage = async () => {
    if (!catalogItems.length) return
    const pending = catalogItems.filter(item => !inLibrary(item.id))
    if (!pending.length) { message.info('当前页短剧均已加入追剧库'); return }
    Modal.confirm({
      title: `当页批量入库 ${pending.length} 部短剧？`,
      content: '将依次解析并加入追剧库（已在追剧库的自动跳过），入库后立即自动下载全部集数。',
      okText: '开始入库',
      onOk: async () => {
        setBatchAdding(true)
        let added = 0, failed = 0
        for (const item of pending) {
          try {
            await api('/api/hg/series', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ url: item.detail_url }) })
            added++
          } catch { failed++ }
        }
        setBatchAdding(false)
        await loadSeries()
        message.success(`批量入库完成：新增 ${added} 部${failed ? `，失败 ${failed} 部` : ''}`)
      }
    })
  }

  const retryAllFailed = () => Modal.confirm({
    title: '批量重试所有下载失败的集数？',
    content: '所有标记为「失败」的集数将重新加入下载队列，下载失败会自动重试 2 次。',
    okText: '开始重试',
    onOk: async () => {
      try {
        const reply = await api<{ queued: number }>('/api/hg/retry-failed-all', { method: 'POST' })
        message.success(`已加入重试队列 ${reply.queued} 集`)
        await loadSeries()
      } catch (error) { message.error(error instanceof Error ? error.message : '操作失败') }
    }
  })
  const downloadAllMissing = () => Modal.confirm({
    title: '批量下载所有短剧的缺失集数？',
    content: '将把追剧库里所有尚未下载的集数全部加入下载队列。',
    okText: '开始下载',
    onOk: async () => {
      try {
        const reply = await api<{ queued: number }>('/api/hg/download-missing-all', { method: 'POST' })
        message.success(`已加入下载队列 ${reply.queued} 集`)
        await loadSeries()
      } catch (error) { message.error(error instanceof Error ? error.message : '操作失败') }
    }
  })

  // 全库扫描：状态轮询（挂载即启动，运行中每 2.5s 刷新）
  useEffect(() => {
    let alive = true
    const tick = async () => {
      try {
        const st = await api<HgScanState>('/api/hg/scan-all/status')
        if (alive) setScan(st)
        if (st.running) window.setTimeout(tick, 2500)
      } catch { if (alive) window.setTimeout(tick, 5000) }
    }
    tick()
    return () => { alive = false }
  }, [])
  const prevScanRunning = useRef(false)
  useEffect(() => {
    if (prevScanRunning.current && scan && !scan.running && scan.finished_at) {
      message.success(`全库扫描结束：新增 ${scan.added} 部，入队 ${scan.queued_episodes} 集`)
      loadSeries()
    }
    prevScanRunning.current = !!scan?.running
  }, [scan])
  const startScanAll = () => Modal.confirm({
    title: '全库扫描入库并下载？',
    content: '将逐页遍历黄果全站各分类列表页（无页数上限，翻到无更多页为止），追剧库中没有的短剧自动解析入库并排队下载全部集数。全程串行抓取带延时防风控，可随时停止。',
    okText: '开始扫描',
    onOk: async () => {
      try {
        await api('/api/hg/scan-all', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}) })
        message.success('全库扫描已启动')
      } catch (error) { message.error(error instanceof Error ? error.message : '启动失败') }
    }
  })
  const stopScanAll = async () => {
    try { await api('/api/hg/scan-all/stop', { method: 'POST' }); message.info('已发送停止指令，将完成当前处理后停止') }
    catch (error) { message.error(error instanceof Error ? error.message : '操作失败') }
  }
  const scanPercent = scan && scan.tabs > 0
    ? Math.min(100, Math.round((scan.tabs_done / scan.tabs) * 100))
    : 0

  const stateTag = (state: string) => {
    if (state === 'completed') return <Tag color="success">已下载</Tag>
    if (state === 'running') return <Tag color="processing">下载中</Tag>
    if (state === 'queued') return <Tag color="blue">排队中</Tag>
    if (state === 'failed') return <Tag color="error">失败</Tag>
    return <Tag>未下载</Tag>
  }
  const uploadTag = (state: string) => {
    if (state === 'uploaded') return <Tag color="success">已上传</Tag>
    if (state === 'uploading') return <Tag color="processing">上传中</Tag>
    if (state === 'failed') return <Tag color="error">上传失败</Tag>
    if (state === 'waiting_complete') return <Tag color="gold">待完结</Tag>
    if (state === 'skipped') return <Tag>仅本地</Tag>
    if (state === 'retry') return <Tag color="blue">待重传</Tag>
    return <Tag>待上传</Tag>
  }

  return <div className="hg-page">
    {scan?.running && <Alert className="hg-scan-alert" type="info" showIcon icon={<LoadingOutlined spin />} message={<Space wrap size={8}><span>全库扫描中：{scan.phase}</span>{scan.current && <Typography.Text type="secondary">当前：{scan.current}</Typography.Text>}</Space>} description={<Space direction="vertical" size={4} style={{ width: '100%' }}><Progress percent={scanPercent} size="small" status="active" /><Typography.Text type="secondary">新增 {scan.added} · 跳过 {scan.skipped} · 失败 {scan.failed} · 入队 {scan.queued_episodes} 集</Typography.Text></Space>} action={<Button size="small" danger icon={<StopOutlined />} onClick={stopScanAll}>停止</Button>} />}
    <Card className="hg-catalog-card" extra={<Space size={8} wrap><Button icon={<ReloadOutlined />} loading={catalogLoading} onClick={() => loadCatalog(catalogTab, catalogPage, keyword, true)}>刷新列表</Button><Button icon={<ScanOutlined />} disabled={!!scan?.running} onClick={startScanAll}>全库扫描入库</Button><Button type="primary" icon={<PlusOutlined />} loading={batchAdding} disabled={!catalogItems.length} onClick={batchAddPage}>当页批量入库{catalogItems.length ? `(${catalogItems.length})` : ''}</Button></Space>}>
      <Space direction="vertical" size={12} style={{ width: '100%' }}>
        <Space wrap>
          <Segmented options={catalogTabs.map(tab => ({ label: tab.name, value: tab.id }))} value={catalogTab}
            onChange={value => { setKeyword(''); loadCatalog(String(value), 1, '') }} />
          <Space.Compact>
            <Button icon={<LeftOutlined />} disabled={catalogLoading || catalogPage <= 1} onClick={() => loadCatalog(catalogTab, catalogPage - 1, keyword)}>上一页</Button>
            <Button style={{ pointerEvents: 'none', minWidth: 92, textAlign: 'center' }} disabled={catalogLoading}>{catalogLoading ? <LoadingOutlined /> : `第 ${catalogPage} 页`}</Button>
            <Button disabled={catalogLoading || catalogItems.length === 0} onClick={() => loadCatalog(catalogTab, catalogPage + 1, keyword)}>下一页<RightOutlined /></Button>
          </Space.Compact>
        </Space>
        <Input.Search value={keyword} onChange={event => setKeyword(event.target.value)} allowClear enterButton="搜索"
          placeholder="搜索短剧名称" loading={catalogLoading} onSearch={value => loadCatalog(catalogTab, 1, value)} />
        <Spin spinning={catalogLoading}>
          {catalogItems.length ? <div className="hg-catalog-grid">{catalogItems.map(item => (
            <Card key={item.id} hoverable className="hg-catalog-item" onClick={() => openCatalogOnline(item.detail_url)}
              cover={<div className="hg-catalog-cover">
                {item.cover_url ? <img src={`/api/proxy-image?url=${encodeURIComponent(item.cover_url)}`} alt={item.title} loading="lazy" onError={retryProxyImage} /> : <PlayCircleOutlined />}
              </div>}
              actions={[<Button key="play" type="link" icon={<PlayCircleOutlined />} onClick={(event) => { event.stopPropagation(); openCatalogOnline(item.detail_url) }}>在线播放</Button>,
                <Button key="add" loading={adding === item.detail_url} icon={<PlusOutlined />} disabled={inLibrary(item.id)} onClick={(event) => { event.stopPropagation(); addSeries(item.detail_url) }}>{inLibrary(item.id) ? '已入库' : '自动入库'}</Button>]}>
              <Card.Meta title={item.title} description={<Space direction="vertical" size={4} style={{ width: '100%' }}><Typography.Text type="secondary">{item.remark || `ID ${item.id}`}</Typography.Text>{catalogStatusTag(item.id)}</Space>} />
            </Card>
          ))}</div> : <Empty description="没有解析到短剧列表" />}
        </Spin>
      </Space>
    </Card>
    <Card className="hg-head-card">
      <Space direction="vertical" size={12} style={{ width: '100%' }}>
        <Space.Compact style={{ width: '100%' }}>
          <Input value={url} onChange={event => setUrl(event.target.value)} onPressEnter={() => addSeries()} placeholder="粘贴黄果短剧播放页或详情页 URL" />
          <Button type="primary" loading={!!adding && adding === url.trim()} icon={<PlusOutlined />} onClick={() => addSeries()}>添加</Button>
        </Space.Compact>
      </Space>
    </Card>
    <div className="hg-layout">
      <Card title="追剧库" extra={<Space size={8} wrap>
        <Select size="small" style={{ width: 150 }} value={seriesFilter} onChange={value => { setSeriesFilter(value); setSeriesPage(1) }} options={[
          { label: `全部 (${series.length})`, value: 'all' },
          { label: `下载中 (${seriesCount(i => (i.active_episodes || []).length > 0)})`, value: 'downloading' },
          { label: `有失败 (${seriesCount(i => (i.failed_count || 0) > 0)})`, value: 'failed' },
          { label: `未下载 (${seriesCount(i => (i.downloaded_episodes || 0) === 0)})`, value: 'undownloaded' },
          { label: `已下完 (${seriesCount(i => (i.total_episodes || 0) > 0 && (i.downloaded_episodes || 0) >= (i.total_episodes || 0))})`, value: 'done' }
        ]} />
        <Button size="small" icon={<ThunderboltOutlined />} onClick={retryAllFailed}>一键重试失败</Button>
        <Button size="small" type="primary" icon={<CloudDownloadOutlined />} onClick={downloadAllMissing}>一键批量下载</Button>
        <Button icon={<ReloadOutlined />} loading={loading} onClick={() => loadSeries()}>刷新</Button>
      </Space>}>
        {filteredSeries.length ? <><div className="hg-series-grid">{pagedSeries.map(item => (
          <Card key={item.id} hoverable size="small" className={active?.id === item.id ? 'hg-series-card active' : 'hg-series-card'} onClick={() => loadEpisodes(item)}>
            <div className="hg-series-poster" aria-hidden>{item.cover_url ? <img src={`/api/hg/cover/${item.id}`} alt="" loading="lazy" onError={event => { event.currentTarget.style.visibility = 'hidden' }} /> : null}</div>
            <div className="hg-series-main">
                <Space size={4} wrap>
                  <Tag color={item.completed ? 'success' : 'processing'}>{item.completed ? '已完结' : '追更中'}</Tag>
                  {seriesStatus(item)}
                  {!!item.failed_count && <Tag color="error">失败 {item.failed_count}</Tag>}
                </Space>
                <Typography.Text strong ellipsis>{item.title}</Typography.Text>
                <Typography.Text type="secondary">共 {item.total_episodes || 0} 集 · 已下载 {item.downloaded_episodes || 0} · 已上传 {item.uploaded_episodes || 0}</Typography.Text>
                {(item.active_episodes || []).length > 0 && (
                  <div className="hg-series-ep-progress">
                    {(item.active_episodes || []).slice(0, 3).map(epItem => (
                      <div key={epItem.ep} className="hg-series-ep-line">
                        <span className="hg-series-ep-label">{epItem.state === 'running' ? '下载中' : '排队中'} 第{epItem.ep}集</span>
                        <Progress percent={Math.round((epItem.progress || 0) * 100)} size="small" showInfo={epItem.state === 'running'} />
                      </div>
                    ))}
                    {(item.active_episodes || []).length > 3 && (
                      <Typography.Text type="secondary" className="hg-series-ep-more">等 {item.active_episodes!.length} 集排队</Typography.Text>
                    )}
                  </div>
                )}
                <Space size={4} wrap className="hg-series-actions">
                  <Button size="small" icon={<PlayCircleOutlined />} onClick={event => { event.stopPropagation(); openSeriesOnline(item) }}>在线播放</Button>
                  <Button size="small" onClick={event => { event.stopPropagation(); setSeriesCompleted(item, !item.completed) }}>{item.completed ? '恢复追更' : '标记完结'}</Button>
                  <Button size="small" disabled={!!item.completed} onClick={event => { event.stopPropagation(); runAction(`/api/hg/series/${item.id}/check`, '已检查更新') }}>追更</Button>
                  <Button size="small" onClick={event => { event.stopPropagation(); runAction(`/api/hg/series/${item.id}/download-missing`, '缺失集已入队') }}>下载缺失</Button>
                  <Button size="small" danger icon={<DeleteOutlined />} onClick={event => { event.stopPropagation(); deleteSeries(item) }}>删除</Button>
                </Space>
            </div>
          </Card>
        ))}</div>{filteredSeries.length > SERIES_PAGE_SIZE && <div className="catalog-pagination"><Pagination current={seriesPageClamped} pageSize={SERIES_PAGE_SIZE} total={filteredSeries.length} showSizeChanger={false} onChange={page => setSeriesPage(page)} /></div>}</> : <Empty description={series.length ? '没有符合筛选条件的短剧' : '暂无短剧，先添加一个黄果播放页'} />}
      </Card>
      <Card title={active ? `${active.title} · 剧集` : '剧集'} extra={active && <Space size={8} wrap>
        <Typography.Text type="secondary">最新第 {active.latest_episode || 0} 集</Typography.Text>
        <Button size="small" icon={<SyncOutlined />} onClick={async () => {
          try {
            const reply = await api<{ queued: number }>(`/api/hg/series/${active.id}/rescrape`, { method: 'POST' })
            message.success(`重新刮削完成${reply.queued ? `，${reply.queued} 集已重新排队下载` : ''}`)
            await loadSeries()
            await loadEpisodes(active)
          } catch (error) { message.error(error instanceof Error ? error.message : '操作失败') }
        }}>重新刮削</Button>
      </Space>}>
        {episodes.length > 0 && <div style={{ overflowX: 'auto', marginBottom: 12 }}><Segmented value={epFilter} onChange={value => setEpFilter(value as typeof epFilter)} options={[
          { label: `全部 (${episodes.length})`, value: 'all' },
          { label: `排队中 (${episodes.filter(e => e.state === 'queued').length})`, value: 'queued' },
          { label: `下载中 (${episodes.filter(e => e.state === 'running').length})`, value: 'running' },
          { label: `已下载 (${episodes.filter(e => e.state === 'completed').length})`, value: 'completed' },
          { label: `失败 (${episodes.filter(e => e.state === 'failed').length})`, value: 'failed' }
        ]} /></div>}
        <Table<HgEpisode> rowKey="id" dataSource={epFilter === 'all' ? episodes : episodes.filter(e => e.state === epFilter)} pagination={{ pageSize: 20 }} locale={{ emptyText: '请选择左侧短剧' }} columns={[
          { title: '集数', dataIndex: 'ep', width: 76, render: value => `第 ${value} 集` },
          { title: '下载', width: 96, render: (_, row) => stateTag(row.state) },
          { title: '上传', width: 96, render: (_, row) => uploadTag(row.upload_state) },
          { title: '进度', width: 120, render: (_, row) => <Progress percent={Math.round((row.progress || 0) * 100)} size="small" /> },
          { title: '说明', render: (_, row) => <><Typography.Text>{row.message || '-'}</Typography.Text>{row.error && <><br /><Typography.Text type="danger">{row.error}</Typography.Text></>}</> },
          { title: '操作', width: 210, render: (_, row) => <Space size={6} wrap>
            {row.file_path && <Button size="small" icon={<PlayCircleOutlined />} onClick={() => onPlayLocal({ name: row.title, path: row.file_path })}>播放</Button>}
            {row.play_url && active && <Button size="small" onClick={() => openSeriesOnline(active, row.ep)}>在线</Button>}
            {row.state !== 'running' && <Button size="small" onClick={() => runAction(`/api/hg/episodes/${row.id}/download`, '已加入下载队列')}>{row.state === 'completed' ? '重下' : '下载'}</Button>}
            {row.upload_state === 'failed' && <Button size="small" icon={<CloudUploadOutlined />} onClick={() => runAction(`/api/hg/episodes/${row.id}/retry-upload`, '已加入上传重试')}>重传</Button>}
          </Space> }
        ]} />
      </Card>
    </div>
    <EpisodePickerModal open={online.open} loading={online.loading} error={online.error}
      title={online.series?.title} cover={online.series?.cover_url}
      subtitle={online.series ? `共 ${online.series.episodes.length} 集 · 在线播放无需下载` : undefined}
      chips={online.series ? online.series.episodes.map(entry => ({ key: String(entry.ep), label: String(entry.ep), disabled: !entry.play_url || entry.locked, hint: entry.file_path ? '已下' : undefined })) : []}
      activeKey={online.playing ? String(online.playing.ep) : undefined}
      onSelect={chip => { const target = online.series?.episodes.find(entry => String(entry.ep) === chip.key); if (target) playOnlineEp(target) }}
      onClose={closeOnline}
      player={online.playing ? <HlsVideo key={online.playing.url} src={online.playing.url} poster={online.series?.cover_url || undefined} /> : undefined} />
  </div>
}

function LogCenterPage({ initialModule = 'all' }: { initialModule?: string }) {
  const [logs, setLogs] = useState<AppLog[]>([])
  const [stats, setStats] = useState<LogStats | null>(null)
  const [loading, setLoading] = useState(false)
  const [moduleFilter, setModuleFilter] = useState(initialModule || 'all')
  const [levelFilter, setLevelFilter] = useState('all')
  const [keyword, setKeyword] = useState('')
  const [active, setActive] = useState<AppLog | null>(null)
  const modules = useMemo(() => {
    const names = new Set(['system', 'access', 'license', 'settings', 'jable', '115', 'download', 'media', 'strm', 'task', 'auto'])
    logs.forEach(item => names.add(item.module))
    stats?.modules?.forEach(item => names.add(item.module))
    return Array.from(names).filter(Boolean)
  }, [logs, stats])

  const buildQuery = () => {
    const params = new URLSearchParams()
    if (moduleFilter !== 'all') params.set('module', moduleFilter)
    if (levelFilter !== 'all') params.set('level', levelFilter)
    if (keyword.trim()) params.set('q', keyword.trim())
    params.set('limit', '200')
    return params
  }

  const load = async () => {
    setLoading(true)
    try {
      const params = buildQuery()
      const [logReply, statReply] = await Promise.all([
        api<{ logs: AppLog[] }>(`/api/logs?${params.toString()}`),
        api<LogStats>('/api/logs/stats')
      ])
      setLogs(logReply.logs || [])
      setStats(statReply)
    } catch (error) {
      message.error(error instanceof Error ? error.message : '日志加载失败')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { load() }, [moduleFilter, levelFilter])
  useEffect(() => {
    if (initialModule && initialModule !== moduleFilter) setModuleFilter(initialModule)
  }, [initialModule])

  const clearLogs = () => {
    Modal.confirm({
      title: '清空日志中心？',
      content: '清空后会保留一条“日志中心已清空”的记录，历史排障信息将不可恢复。',
      okText: '清空',
      okButtonProps: { danger: true },
      cancelText: '取消',
      async onOk() {
        await api('/api/logs', { method: 'DELETE' })
        message.success('日志已清空')
        await load()
      }
    })
  }

  const levelTag = (level: AppLog['level']) => {
    const colors: Record<string, string> = { debug: 'default', info: 'blue', success: 'success', warning: 'warning', error: 'error' }
    const labels: Record<string, string> = { debug: '调试', info: '信息', success: '成功', warning: '警告', error: '错误' }
    return <Tag color={colors[level] || 'default'}>{labels[level] || level}</Tag>
  }

  return <div className="log-center">
    <div className="log-stat-grid">
      <Card><Statistic title="今日日志" value={Object.values(stats?.today || {}).reduce((sum, n) => sum + Number(n || 0), 0)} /></Card>
      <Card><Statistic title="今日错误" value={stats?.today?.error || 0} valueStyle={{ color: '#cf1322' }} /></Card>
      <Card><Statistic title="今日警告" value={stats?.today?.warning || 0} valueStyle={{ color: '#d48806' }} /></Card>
      <Card><Statistic title="总记录" value={stats?.total || 0} /></Card>
    </div>
    {stats?.last_error && <Alert className="log-last-error" type="error" showIcon
      message={`${stats.last_error.module}.${stats.last_error.action}: ${stats.last_error.message}`}
      description={stats.last_error.target || stats.last_error.created_at} />}
    <div className="toolbar-row log-toolbar">
      <Space wrap size={8}>
        <Select value={moduleFilter} onChange={setModuleFilter} style={{ width: 150 }}
          options={[{ label: '全部模块', value: 'all' }, ...modules.map(module => ({ label: module, value: module }))]} />
        <Select value={levelFilter} onChange={setLevelFilter} style={{ width: 130 }} options={[
          { label: '全部级别', value: 'all' }, { label: '错误', value: 'error' }, { label: '警告', value: 'warning' },
          { label: '成功', value: 'success' }, { label: '信息', value: 'info' }, { label: '调试', value: 'debug' }
        ]} />
        <Input.Search allowClear placeholder="搜索消息、任务、目标..." value={keyword}
          onChange={event => setKeyword(event.target.value)}
          onSearch={() => load()} style={{ width: 280 }} />
      </Space>
      <Space wrap size={8}>
        <Button icon={<ReloadOutlined />} loading={loading} onClick={load}>刷新</Button>
        <Button icon={<FileTextOutlined />} onClick={() => window.open('/api/logs/export', '_blank')}>导出</Button>
        <Button danger icon={<DeleteOutlined />} onClick={clearLogs}>清空</Button>
      </Space>
    </div>
    <Table<AppLog> rowKey="id" loading={loading} dataSource={logs} pagination={{ pageSize: 20 }}
      tableLayout="fixed" scroll={{ x: 900 }}
      locale={{ emptyText: '暂无日志记录' }} columns={[
        { title: '时间', dataIndex: 'created_at', width: 170 },
        { title: '级别', dataIndex: 'level', width: 92, render: levelTag },
        { title: '模块', width: 170, render: (_, row) => <><Typography.Text strong>{row.module}</Typography.Text><br /><Typography.Text type="secondary">{row.action}</Typography.Text></> },
        { title: '消息', render: (_, row) => <><Typography.Text>{row.message}</Typography.Text>{row.target && <><br /><Typography.Text type="secondary" ellipsis>{row.target}</Typography.Text></>}</> },
        { title: '任务', dataIndex: 'task_id', width: 110, render: value => value ? <Typography.Text code>{value.slice(0, 8)}</Typography.Text> : <Typography.Text type="secondary">-</Typography.Text> },
        { title: '详情', width: 86, render: (_, row) => <Button size="small" onClick={() => setActive(row)}>查看</Button> }
      ]} />
    <Drawer title="日志详情" open={!!active} width={620} onClose={() => setActive(null)}>
      {active && <>
        <Descriptions column={1} size="small" bordered items={[
          { key: 'time', label: '时间', children: active.created_at },
          { key: 'level', label: '级别', children: levelTag(active.level) },
          { key: 'module', label: '模块', children: `${active.module}.${active.action}` },
          { key: 'target', label: '目标', children: active.target || '-' },
          { key: 'task', label: '任务', children: active.task_id || '-' },
          { key: 'message', label: '消息', children: active.message },
        ]} />
        <Typography.Title level={5}>明细</Typography.Title>
        <pre className="log-detail-pre">{active.detail || '无更多明细'}</pre>
      </>}
    </Drawer>
  </div>
}

function TaskListPage({ downloads, cloudTasks, hgTasks, onDeleteCloud, onPlayStrm, onPlayPickcode, onRefresh, refreshing, onPoll115, onRetryHg }: {
  downloads: DownloadTask[]; cloudTasks: CloudTask[]; hgTasks: HgEpisodeTask[]
  onDeleteCloud: (id: string) => void; onPlayStrm: (item: StrmItem) => void
  onPlayPickcode: (pickcode: string, title: string) => void
  onRefresh: () => void; refreshing: boolean; onPoll115: () => void; onRetryHg: (id: string) => void
}) {
  const [source, setSource] = useState<'all' | 'local' | 'cloud' | 'huangguo'>('all')
  const [keyword, setKeyword] = useState('')

  const rows: TaskRow[] = useMemo(() => [
    ...downloads.map(t => ({ key: `local-${t.id}`, source: 'local' as const, catalog: t.catalog || t.title, title: t.title, cover_url: t.cover_url, state: t.state, created_at: t.created_at, local: t })),
    ...cloudTasks.map(t => ({ key: `cloud-${t.id}`, source: 'cloud' as const, catalog: t.catalog || t.title, title: t.title, cover_url: t.cover_url, state: t.state, created_at: t.created_at, cloud: t })),
    ...hgTasks.map(t => ({ key: `hg-${t.id}`, source: 'huangguo' as const, catalog: t.series_title || '黄果短剧', title: `第${t.ep}集 ${t.episode_title || ''}`.trim(), cover_url: t.series_id ? `/api/hg/cover/${t.series_id}` : '', state: t.state, created_at: t.updated_at || t.created_at, hg: t })),
  ].sort((a, b) => (b.created_at || '').localeCompare(a.created_at || '')), [downloads, cloudTasks, hgTasks])

  const kw = keyword.trim().toLowerCase()
  const filtered = rows.filter(row =>
    (source === 'all' || row.source === source) &&
    (!kw || row.catalog.toLowerCase().includes(kw) || row.title.toLowerCase().includes(kw)))

  const stateTag = (state: string) => {
    if (state === 'completed') return <Tag color="success">完成</Tag>
    if (state === 'running' || state === 'downloading' || state === 'processing') return <Tag color="processing">进行中</Tag>
    if (state === 'failed' || state === 'error') return <Tag color="error">失败</Tag>
    if (state === 'interrupted') return <Tag color="warning">已中断</Tag>
    if (state === 'skipped') return <Tag color="default">跳过</Tag>
    return <Tag color="default">等待中</Tag>
  }
  const stepTag = (value?: string) => {
    if (!value || value === 'pending') return null
    if (value === 'running') return <Tag color="processing">进行中</Tag>
    if (value === 'succeeded') return <Tag color="success">完成</Tag>
    if (value === 'failed') return <Tag color="error">失败</Tag>
    if (value === 'skipped') return <Tag color="default">跳过</Tag>
    return <Tag>{value}</Tag>
  }
  const typeTag = (t?: string) => t === 'manual_scrape' ? <Tag color="purple">手动刮削</Tag>
    : t === 'history' ? <Tag color="cyan">历史重刮</Tag> : null

  const localActions = (t: DownloadTask) => {
    if (t.state === 'completed') return <Button size="small" icon={<PlayCircleOutlined />} onClick={() => window.open(`/api/tasks/${t.id}/play`, '_blank')}>播放</Button>
    if (t.state === 'interrupted' || t.state === 'failed') return <Button size="small" type="primary" ghost onClick={async () => {
      try { await api(`/api/tasks/${t.id}/retry`, { method: 'POST' }); message.success('已加入重试队列'); onRefresh() }
      catch (error) { message.error(error instanceof Error ? error.message : '重试失败') }
    }}>重试</Button>
    return <Typography.Text type="secondary">{t.phase}</Typography.Text>
  }
  const cloudActions = (t: CloudTask) => {
    const play = t.pickcode
      ? <Button type="primary" size="small" icon={<PlayCircleOutlined />} onClick={() => onPlayPickcode(t.pickcode!, `${t.catalog || ''} ${t.title}`.trim())}>播放</Button>
      : t.strm_id
        ? <Button type="primary" size="small" icon={<PlayCircleOutlined />} onClick={() => onPlayStrm({ id: t.strm_id!, catalog: t.catalog, title: t.title, file_path: t.file_path, created_at: t.created_at })}>播放</Button>
        : t.state === 'completed' ? <Typography.Text type="secondary">无直链</Typography.Text>
        : <Typography.Text type="secondary">等待结果</Typography.Text>
    return <Space size={4}>{play}<Button size="small" danger type="text" onClick={() => onDeleteCloud(t.id)}>删除</Button></Space>
  }
  const uploadTag = (v?: string) => {
    if (!v || v === 'pending') return null
    if (v === 'uploaded') return <Tag color="blue">已上传115</Tag>
    if (v === 'uploading') return <Tag color="processing">上传中</Tag>
    if (v === 'failed') return <Tag color="error">上传失败</Tag>
    if (v === 'waiting_complete') return <Tag color="default">等待完结上传</Tag>
    if (v === 'retry') return <Tag color="warning">等待重新上传</Tag>
    return null
  }
  const hgActions = (t: HgEpisodeTask) => <Space size={4}>
    {(t.state === 'failed' || t.state === 'pending') && <Button size="small" type="primary" ghost onClick={() => onRetryHg(t.id)}>重试</Button>}
  </Space>
  const mobileActions = (row: TaskRow) => row.local ? localActions(row.local) : row.hg ? hgActions(row.hg) : cloudActions(row.cloud!)
  const mobileDescription = (row: TaskRow) => row.local ? (
    <>
      <Progress percent={Math.round((row.local.progress || 0) * 100)} size="small" />
      <Typography.Text type="secondary">{row.local.speed || '-'} / {row.local.size || '-'}</Typography.Text>
      {(row.local.scrape_step || row.local.organize_step) && <div>{stepTag(row.local.scrape_step)}{stepTag(row.local.organize_step)}</div>}
    </>
  ) : row.hg ? (
    <>
      {row.hg.state === 'failed' && row.hg.error ? <Typography.Text type="danger" ellipsis>{row.hg.error}</Typography.Text>
        : <Typography.Text type="secondary">{row.hg.message || row.state}</Typography.Text>}
      {row.hg.state !== 'completed' && <Progress percent={Math.round(row.hg.progress || 0)} size="small" />}
      {uploadTag(row.hg.upload_state)}
    </>
  ) : (
    <>
      <Typography.Text type="secondary">{row.cloud?.message || row.state}</Typography.Text>
      {row.cloud?.file_path && <Typography.Text type="secondary" ellipsis>{row.cloud.file_path}</Typography.Text>}
    </>
  )

  return <>
    <div className="toolbar-row" style={{ marginBottom: 16 }}>
      <Segmented options={[{ label: `全部 (${rows.length})`, value: 'all' }, { label: `本地 (${downloads.length})`, value: 'local' }, { label: `115离线 (${cloudTasks.length})`, value: 'cloud' }, { label: `黄果 (${hgTasks.length})`, value: 'huangguo' }]} value={source} onChange={value => setSource(value as 'all' | 'local' | 'cloud' | 'huangguo')} />
      <Input.Search placeholder="按番号或标题搜索..." allowClear style={{ maxWidth: 280 }} onSearch={setKeyword} onChange={e => { if (!e.target.value) setKeyword('') }} />
      <Space size={8}>
        <Button icon={<CloudServerOutlined />} loading={refreshing} onClick={onPoll115}>同步 115</Button>
        <Button icon={<ReloadOutlined />} onClick={onRefresh}>刷新</Button>
      </Space>
    </div>
    <div className="task-mobile-list">
      {!filtered.length ? <Empty description="暂无下载任务：在影片详情中可本地下载或离线到 115" /> : filtered.map(row => (
        <Card key={row.key} size="small" className="task-mobile-card">
          <div className="task-mobile-row">
            <PosterThumb src={row.cover_url || ''} catalog={row.catalog} width={58} />
            <div className="task-mobile-main">
              <Space size={4} wrap>{row.source === 'local' ? <Tag color="blue">本地</Tag> : row.source === 'huangguo' ? <Tag color="orange">黄果</Tag> : <Tag color="geekblue">115离线</Tag>}{stateTag(row.state)}{row.local && typeTag(row.local.task_type)}{row.hg && uploadTag(row.hg.upload_state)}</Space>
              <Typography.Text strong ellipsis>{row.catalog || row.title}</Typography.Text>
              <Typography.Text type="secondary" ellipsis>{row.title}</Typography.Text>
              <div className="task-mobile-desc">{mobileDescription(row)}</div>
              <div className="task-mobile-actions">{mobileActions(row)}</div>
            </div>
          </div>
        </Card>
      ))}
    </div>
    <Table className="task-table" rowKey="key" dataSource={filtered} pagination={{ pageSize: 12 }} locale={{ emptyText: '暂无下载任务：在影片详情中可本地下载或离线到 115' }} columns={[
      { title: '封面', width: 84, render: (_, row) => <PosterThumb src={row.cover_url || ''} catalog={row.catalog} /> },
      { title: '影片', render: (_, row) => <><Typography.Text strong>{row.catalog || row.title}</Typography.Text><br /><Typography.Text type="secondary">{row.title}</Typography.Text></> },
      { title: '来源', width: 130, render: (_, row) => <Space size={4} wrap>{row.source === 'local' ? <Tag color="blue">本地</Tag> : row.source === 'huangguo' ? <Tag color="orange">黄果</Tag> : <Tag color="geekblue">115离线</Tag>}{row.local && typeTag(row.local.task_type)}{row.hg && uploadTag(row.hg.upload_state)}</Space> },
      { title: '状态', width: 90, render: (_, row) => stateTag(row.state) },
      { title: '进度 / 说明', render: (_, row) => row.local ? (
        <div style={{ minWidth: 150 }}>
          <Progress percent={Math.round((row.local.progress || 0) * 100)} size="small" />
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>{row.local.speed || '-'} / {row.local.size || '-'}</Typography.Text>
          {(row.local.scrape_step || row.local.organize_step) && <div style={{ marginTop: 4 }}>{stepTag(row.local.scrape_step)}{stepTag(row.local.organize_step)}</div>}
        </div>
      ) : row.hg ? (
        <div style={{ minWidth: 150 }}>
          {row.hg.state === 'failed' && row.hg.error ? <Typography.Text type="danger" style={{ fontSize: 12 }}>{row.hg.error}</Typography.Text>
            : <Typography.Text type="secondary" style={{ fontSize: 12 }}>{row.hg.message || '-'}</Typography.Text>}
          {row.hg.state !== 'completed' && <Progress percent={Math.round(row.hg.progress || 0)} size="small" />}
        </div>
      ) : <Typography.Text type="secondary">{row.cloud?.message || '-'}</Typography.Text> },
      { title: '创建时间', dataIndex: 'created_at', width: 170 },
      { title: '操作', width: 160, render: (_, row) => row.local ? localActions(row.local) : row.hg ? hgActions(row.hg) : cloudActions(row.cloud!) },
    ]} />
  </>
}

type HgEpisodeEntry = { id: string; title: string; catalog: string; strm?: StrmItem; local_path?: string }

function MediaLibraryPage({ strmItems, onPlayStrm, onDeleteStrm, onPlayLocal, onRefresh }: {
  strmItems: StrmItem[]
  onPlayStrm: (item: StrmItem) => void
  onDeleteStrm: (id: string) => void
  onPlayLocal: (item: { path: string; name: string }) => void
  onRefresh: () => void
}) {
  const [localFiles, setLocalFiles] = useState<{ path: string; name: string; size: number }[]>([])
  const [source, setSource] = useState<'all' | '115' | 'local'>('all')
  const [keyword, setKeyword] = useState('')
  const [libPage, setLibPage] = useState(1)
  const [hgEpisodes, setHgEpisodes] = useState<{ catalog: string; cover?: string; items: HgEpisodeEntry[] } | null>(null)
  useEffect(() => {
    // 部署重启窗口内首次请求可能失败：失败后自动重试最多 4 次，避免本地列表静默归零
    let cancelled = false
    const attempt = async (count: number): Promise<void> => {
      try {
        const data = await api<{ path: string; name: string; size: number }[]>('/api/media-files')
        if (!cancelled) setLocalFiles(data)
      } catch {
        if (!cancelled && count < 4) setTimeout(() => { void attempt(count + 1) }, 2000 * count)
      }
    }
    void attempt(1)
    return () => { cancelled = true }
  }, [])

  const catalogCover = new Map<string, StrmItem>()
  for (const item of strmItems) if (item.catalog) catalogCover.set(item.catalog.toUpperCase(), item)
  const catalogRegex = /([A-Z]{2,6}-\d{1,4})/i

  // 黄果短剧：同一部剧的分集（id 前缀 hg_）聚合成一个剧集卡片，点进去选集播放
  const hgGroups = new Map<string, StrmItem[]>()
  for (const item of strmItems) {
    if (!String(item.id).startsWith('hg_')) continue
    const key = item.catalog || '未命名短剧'
    const list = hgGroups.get(key) || []
    list.push(item)
    hgGroups.set(key, list)
  }
  // 本地黄果短剧：黄果短剧/<剧名>/第XXX集.mp4 聚合成一张剧集卡片，点进去选集本地播放
  const localSeries = new Map<string, { path: string; name: string; size: number; ep: number }[]>()
  const plainLocalFiles: typeof localFiles = []
  for (const file of localFiles) {
    const m = /^黄果短剧\/([^/]+)\/第(\d+)集\.[^.]+$/.exec(file.name)
    if (m) {
      const list = localSeries.get(m[1]) || []
      list.push({ ...file, ep: Number(m[2]) })
      localSeries.set(m[1], list)
    } else {
      plainLocalFiles.push(file)
    }
  }
  const entries: {
    key: string; kind: '115' | 'local'; catalog: string; title: string
    posterPath?: string; coverUrl?: string; directCover?: string; sizeText?: string; filePath?: string
    item?: StrmItem; local?: { path: string; name: string }; episodes?: HgEpisodeEntry[]
  }[] = [
    ...Array.from(hgGroups.entries()).map(([catalogKey, list]) => {
      const sorted = [...list].sort((a, b) => a.title.localeCompare(b.title, 'zh', { numeric: true }))
      const withPoster = sorted.find(ep => ep.poster_path) || sorted[0]
      return {
        key: `hgseries-${catalogKey}`, kind: '115' as const, catalog: catalogKey,
        title: `短剧 · 共 ${sorted.length} 集`, posterPath: withPoster?.poster_path, coverUrl: withPoster?.cover_url,
        item: withPoster, episodes: sorted.map(ep => ({ id: ep.id, title: ep.title, catalog: ep.catalog || catalogKey, strm: ep }))
      }
    }),
    ...strmItems.filter(item => !String(item.id).startsWith('hg_')).map(item => ({
      key: `115-${item.id}`, kind: '115' as const, catalog: item.catalog || '未识别番号', title: item.title,
      posterPath: item.poster_path, coverUrl: item.cover_url, filePath: item.file_path, item
    })),
    ...Array.from(localSeries.entries()).map(([seriesName, list]) => {
      const sorted = [...list].sort((a, b) => a.ep - b.ep)
      const first = sorted[0]
      const base = first.name.split('/').pop() || first.name
      return {
        key: `localseries-${seriesName}`, kind: 'local' as const, catalog: seriesName,
        title: `短剧 · 共 ${sorted.length} 集`,
        posterPath: '', coverUrl: '', directCover: `/api/hg/local-cover?name=${encodeURIComponent(seriesName)}`,
        sizeText: `${(first.size / 1024 ** 3).toFixed(2)} GB`,
        local: { path: first.path, name: base },
        episodes: sorted.map(f => ({ id: f.path, title: `第${f.ep}集`, catalog: seriesName, local_path: f.path }))
      }
    }),
    ...plainLocalFiles.map(file => {
      const match = catalogRegex.exec(file.name)
      const catalog = match ? match[1].toUpperCase() : ''
      const ref = catalog ? catalogCover.get(catalog) : undefined
      const base = file.name.split('/').pop() || file.name
      return {
        key: `local-${file.path}`, kind: 'local' as const,
        catalog: catalog || base.replace(/\.[^.]+$/, ''), title: base,
        posterPath: '', coverUrl: ref?.cover_url || '', sizeText: `${(file.size / 1024 ** 3).toFixed(2)} GB`,
        local: { path: file.path, name: base }
      }
    })
  ]
  const kw = keyword.trim().toLowerCase()
  const filtered = entries.filter(entry =>
    (source === 'all' || entry.kind === source) &&
    (!kw || entry.catalog.toLowerCase().includes(kw) || entry.title.toLowerCase().includes(kw)))
  const counts = { '115': strmItems.length, local: localFiles.length }
  const LIB_PAGE_SIZE = 24
  const libPageClamped = Math.max(1, Math.min(libPage, Math.max(1, Math.ceil(filtered.length / LIB_PAGE_SIZE))))
  const pageEntries = filtered.slice((libPageClamped - 1) * LIB_PAGE_SIZE, libPageClamped * LIB_PAGE_SIZE)

  return <>
    <div className="toolbar-row" style={{ marginBottom: 16 }}>
      <Segmented options={[{ label: `全部 (${entries.length})`, value: 'all' }, { label: `115 (${counts['115']})`, value: '115' }, { label: `本地 (${counts.local})`, value: 'local' }]} value={source} onChange={value => { setSource(value as 'all' | '115' | 'local'); setLibPage(1) }} />
      <Input.Search placeholder="按番号或标题搜索..." allowClear style={{ maxWidth: 320 }} onSearch={value => { setKeyword(value); setLibPage(1) }} onChange={e => { if (!e.target.value) { setKeyword(''); setLibPage(1) } }} />
      <Button icon={<ReloadOutlined />} onClick={() => { onRefresh(); api<typeof localFiles>('/api/media-files').then(setLocalFiles).catch(() => undefined) }}>刷新</Button>
    </div>
    {!filtered.length
      ? <Empty description={entries.length ? '没有匹配的影片' : '媒体库为空：离线到 115 或本地下载入库后自动出现'} />
      : <div className="strm-grid">{pageEntries.map(entry => {
        const posterSrc = entry.posterPath && entry.item
          ? `/api/strm-library/${entry.item.id}/poster`
          : entry.coverUrl ? `/api/proxy-image?url=${encodeURIComponent(entry.coverUrl)}` : entry.directCover || ''
        return <Card key={entry.key} hoverable className="strm-card" onClick={() => {
          if (entry.episodes?.length) { setHgEpisodes({ catalog: entry.catalog, cover: posterSrc, items: entry.episodes }); return }
          if (entry.kind === '115' && entry.item) onPlayStrm(entry.item)
        }}
          cover={<div className="strm-poster">
            <Tag color={entry.kind === '115' ? 'geekblue' : 'green'} className="strm-tag">{entry.kind === '115' ? '115' : '本地'}</Tag>
            {posterSrc ? <img src={posterSrc} alt={entry.catalog} loading="lazy" /> : <div className="strm-poster-fallback"><PlayCircleOutlined style={{ fontSize: 42, opacity: 0.7 }} /></div>}
            <div className="strm-poster-play"><PlayCircleOutlined /></div>
          </div>}
          actions={entry.episodes?.length
            ? [<Button key="eps" type="link" icon={<PlaySquareOutlined />} onClick={event => { event.stopPropagation(); setHgEpisodes({ catalog: entry.catalog, cover: posterSrc, items: entry.episodes! }) }}>分集播放</Button>]
            : entry.kind === '115' && entry.item
            ? [<Button key="play" type="link" icon={<PlayCircleOutlined />} onClick={event => { event.stopPropagation(); onPlayStrm(entry.item!) }}>播放</Button>,
               <Button key="del" type="link" danger icon={<DeleteOutlined />} onClick={event => { event.stopPropagation(); onDeleteStrm(entry.item!.id) }}>删除</Button>]
            : [<Button key="play" type="link" icon={<PlayCircleOutlined />} onClick={event => { event.stopPropagation(); onPlayLocal(entry.local!) }}>播放</Button>,
               entry.filePath ? <Typography.Text key="path" type="secondary" copyable={{ text: entry.filePath }} style={{ fontSize: 12 }}>路径</Typography.Text> : <span key="size" style={{ fontSize: 12, color: '#999' }}>{entry.sizeText}</span>]}>
          <Card.Meta title={<span>{entry.catalog} <Typography.Text type="secondary" style={{ fontSize: 12, fontWeight: 400 }}>{entry.sizeText}</Typography.Text></span>}
            description={<Typography.Paragraph ellipsis={{ rows: 2 }} type="secondary">{entry.title}</Typography.Paragraph>} />
        </Card>
      })}</div>}
    {filtered.length > LIB_PAGE_SIZE && <div className="catalog-pagination" style={{ marginTop: 16 }}><Pagination current={libPageClamped} pageSize={LIB_PAGE_SIZE} total={filtered.length} showSizeChanger={false} showTotal={total => `共 ${total} 部`} onChange={value => setLibPage(value)} /></div>}
    <EpisodePickerModal open={!!hgEpisodes} title={hgEpisodes?.catalog} cover={hgEpisodes?.cover}
      subtitle={hgEpisodes ? `共 ${hgEpisodes.items.length} 集 · 点击分集立即播放` : undefined}
      chips={hgEpisodes ? hgEpisodes.items.map((ep, index) => ({ key: ep.id, label: epChipLabel(ep.title, index) })) : []}
      onSelect={chip => {
        const item = hgEpisodes?.items.find(entry => entry.id === chip.key)
        if (!item) return
        if (item.local_path) onPlayLocal({ path: item.local_path, name: item.title })
        else if (item.strm) onPlayStrm(item.strm)
      }}
      onClose={() => setHgEpisodes(null)} />
  </>
}

createRoot(document.getElementById('root')!).render(<ConfigProvider theme={{ token: { colorPrimary: '#007AFF', colorInfo: '#007AFF', borderRadius: 10, colorBgLayout: '#F2F2F7', fontFamily: 'PingFang SC, Microsoft YaHei, sans-serif' } }}><AntApp><App /></AntApp></ConfigProvider>)
