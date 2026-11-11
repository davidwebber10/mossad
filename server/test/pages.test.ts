import { describe, expect, it } from 'vitest';
import { clock, css, homePage, lockedPage, md, notFoundPage, pinPage, sharePage } from '../src/pages';
import type { Share } from '../src/types';

const full: Share = {
  title: 'Budget review', start: '2026-11-03T21:00:00Z', end: '2026-11-03T22:10:00Z', people: ['Dana Lee', 'Jennifer Lee'], owner: 'Dana Lee',
  summary: 'We held spend flat.', topics: [{ title: 'First quarter', summary: 'Spend is **flat**.' }], decisions: [{ text: 'Hold spend', at: 3128 }],
  actionItems: [{ task: 'Send the numbers', owner: 'Jennifer Lee', text: 'Jennifer Lee: Send the numbers' }, { task: 'Book the room', text: 'Book the room' },
    { task: 'Write the memo', owner: 'Dana Lee', text: 'Dana Lee: Write the memo' }, { task: 'Call the vendor', owner: 'Jennifer Lee', text: 'Jennifer Lee: Call the vendor' }],
  lines: [{ at: 65, speaker: 'Jennifer Lee', text: 'I need the numbers by Friday.' }, { at: 80, speaker: 'Jennifer Lee', text: 'Then finance has two days.' },
    { at: 3725, speaker: 'Dana Lee', text: 'Then we hold.' }],
  audio: false, chat: false, expires: null, timeZone: 'America/Chicago',
};

const page = { origin: 'https://notes.example.com', pin: false };

describe('share page', () => {
  it('renders bold and lists, and escapes everything else', () => {
    expect(md('Spend is **flat**.\n- One\n- <b>Two</b>')).toBe('<p>Spend is <b>flat</b>.</p><ul><li>One</li><li>&#60;b&#62;Two&#60;/b&#62;</li></ul>');
  });

  it('lists decisions in either shape, escaped', () => {
    const html = sharePage({ title: 'T', start: '2026-11-03T15:00:00Z', end: '2026-11-03T15:30:00Z', people: ['Dana'], owner: 'Dana',
      summary: 'S', decisions: ['Old <b>', { text: 'New', at: 3128 }], audio: false, chat: false, expires: null }, 'tok', 'n', page);
    expect(html).toContain('<li>Old &#60;b&#62;</li>');
    expect(html).toContain('<li>New <span class="t">52:08</span></li>');
  });

  it('puts decision times beside plain-string decisions', () => {
    const html = sharePage({ title: 'T', start: '2026-11-03T15:00:00Z', end: '2026-11-03T15:30:00Z', people: ['Dana'], owner: 'Dana',
      summary: 'S', decisions: ['A', 'B'], decisionTimes: [null, 61], audio: false, chat: false, expires: null }, 'tok', 'n', page);
    expect(html).toContain('<li>A</li>');
    expect(html).toContain('<li>B <span class="t">1:01</span></li>');
  });

  it('shows only the shared parts, escaped, with no outside resources', () => {
    const html = sharePage({ title: '<script>x</script>', start: '2026-11-03T15:00:00Z', end: '2026-11-03T15:30:00Z', people: ['Dana'], owner: 'Dana',
      lines: [{ at: 5, speaker: 'Dana', text: 'Hi' }], audio: false, chat: false, expires: null }, 'tok', 'n', page);
    expect(html).not.toContain('<script>x</script>');
    expect(html).toContain('Transcript</h2>');
    expect(html).not.toContain('Summary</h2>');
    expect(html).not.toMatch(/(src|href)="https?:/);
    expect(html).not.toMatch(/url\(https?:/);
    expect(html).toContain('noindex');
  });

  it('does not name the software, in the page or in what a link preview reads', () => {
    for (const html of [sharePage(full, 'tok', 'n', page), notFoundPage('n'), pinPage('n', 'tok'), lockedPage('n'), homePage('n')]) expect(html).not.toMatch(/mossad/i);
    const html = sharePage(full, 'tok', 'n', page);
    expect(html).toContain('<title>Budget review</title>');
    expect(html).toContain('<meta property="og:title" content="Budget review">');
    expect(html).not.toContain('og:site_name');
  });

  it('puts each task under the person who has it, and tasks with no owner last', () => {
    const html = sharePage(full, 'tok', 'n', page);
    expect(html).toContain('<div class="grp"><h3>Jennifer Lee</h3><ul><li>Send the numbers</li><li>Call the vendor</li></ul></div>');
    expect(html.indexOf('<h3>Dana Lee</h3>')).toBeGreaterThan(html.indexOf('<h3>Jennifer Lee</h3>'));
    expect(html.indexOf('No owner')).toBeGreaterThan(html.indexOf('<h3>Dana Lee</h3>'));
  });

  it('names a speaker once for the lines that follow each other, and sets every time to one width', () => {
    const html = sharePage(full, 'tok', 'n', page);
    expect(html.match(/class="ln turn"/g)).toHaveLength(2);
    expect(html.match(/class="ln same"/g)).toHaveLength(1);
    expect(html).toContain('<span class="t">0:01:05</span>');
    expect(html).toContain('<span class="t">1:02:05</span>');
    expect(clock(65, false)).toBe('1:05');
  });

  it('makes a time a control only when there is a recording or a transcript to go to', () => {
    const none = sharePage({ ...full, lines: undefined, audio: false }, 'tok', 'n', page);
    expect(none).toContain('<li>Hold spend <span class="t">0:52:08</span></li>');
    const audio = sharePage({ ...full, audio: true }, 'tok', 'n', page);
    expect(audio).toContain('data-go="3128"');
    expect(audio).toContain('<audio id="audio" controls preload="metadata" src="/tok/audio">');
    expect(audio).toContain('data-go="65"');
  });

  it('shows the chat only on a share that has it', () => {
    expect(sharePage(full, 'tok', 'n', page)).not.toContain('id="ask"');
    expect(sharePage({ ...full, chat: true }, 'tok', 'n', page)).toContain('id="ask"');
  });

  it('says when the link stops, in the owner\'s time zone', () => {
    expect(sharePage({ ...full, expires: '2026-12-04T03:00:00Z' }, 'tok', 'n', page)).toContain('The link stops working on December 3, 2026.');
    expect(sharePage(full, 'tok', 'n', page)).not.toContain('stops working');
  });

  it('breaks a long word, an address, or a link so the page never scrolls sideways', () => {
    const long = 'Quarterly_budget_review_for_the_northern_region_and_partners_2026';
    expect(long.length).toBeGreaterThan(60);
    const html = sharePage({ ...full, title: long, people: ['jennifer.lee.finance.department@example.com'] }, 'tok', 'n', page);
    expect(html).toContain(long);
    const rule = /([^{}]+)\{[^}]*overflow-wrap:anywhere/.exec(css)!;
    for (const part of ['h1', '.names', '.prose', '.ln p', '.grp li', '.dec li']) expect(rule[1].trim().split(',')).toContain(part);
  });

  it('sets small gray text dark enough to read: 4.5 to 1 on the paper', () => {
    const ratio = (a: string, b: string) => {
      const lum = (hex: string) => {
        const [r, g, bl] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
        return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
      };
      const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m);
      return (x + 0.05) / (y + 0.05);
    };
    const values = [...css.matchAll(/--paper:(#[0-9a-f]{6});[^}]*?--faint:(#[0-9a-f]{6})/g)].map((m) => [m[1], m[2]]);
    expect(values.length).toBeGreaterThanOrEqual(2);
    for (const [paper, faint] of values) expect(ratio(paper, faint)).toBeGreaterThanOrEqual(4.5);
  });

  it('lets a person correct the PIN before it is sent, and names the message in the title', () => {
    const html = pinPage('n', 'tok', 'That PIN is not right. 4 tries left before a pause.');
    expect(html).not.toContain('requestSubmit');
    expect(html).toContain('<title>That PIN is not right. 4 tries left before a pause. Private page</title>');
    expect(pinPage('n', 'tok')).toContain('<title>Private page</title>');
  });

  it('gives the player a position and a speed that a screen reader can say', () => {
    const html = sharePage({ ...full, audio: true }, 'tok', 'n', page);
    expect(html).toContain('aria-valuetext');
    expect(html).toContain('aria-label="Speed, 1 times"');
  });
});
