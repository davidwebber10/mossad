import { describe, expect, it } from 'vitest';
import { md, sharePage } from '../src/pages';

describe('share page', () => {
  it('renders bold and lists, and escapes everything else', () => {
    expect(md('Spend is **flat**.\n- One\n- <b>Two</b>')).toBe('<p>Spend is <b>flat</b>.</p><ul><li>One</li><li>&#60;b&#62;Two&#60;/b&#62;</li></ul>');
  });

  it('lists decisions in either shape, escaped', () => {
    const html = sharePage({ title: 'T', start: '2026-11-03T15:00:00Z', end: '2026-11-03T15:30:00Z', people: ['Dana'], owner: 'Dana',
      summary: 'S', decisions: ['Old <b>', { text: 'New', at: 3128 }], audio: false, chat: false, expires: null }, 'tok', 'n', 'https://github.com/x/y');
    expect(html).toContain('<li>Old &#60;b&#62;</li>');
    expect(html).toContain('<li>[00:52:08] New</li>');
  });

  it('puts decision times beside plain-string decisions', () => {
    const html = sharePage({ title: 'T', start: '2026-11-03T15:00:00Z', end: '2026-11-03T15:30:00Z', people: ['Dana'], owner: 'Dana',
      summary: 'S', decisions: ['A', 'B'], decisionTimes: [null, 61], audio: false, chat: false, expires: null }, 'tok', 'n', 'https://github.com/x/y');
    expect(html).toContain('<li>A</li>');
    expect(html).toContain('<li>[00:01:01] B</li>');
  });

  it('shows only the shared parts, escaped, with no outside resources', () => {
    const html = sharePage({ title: '<script>x</script>', start: '2026-11-03T15:00:00Z', end: '2026-11-03T15:30:00Z', people: ['Dana'], owner: 'Dana',
      lines: [{ at: 5, speaker: 'Dana', text: 'Hi' }], audio: false, chat: false, expires: null }, 'tok', 'n', 'https://github.com/x/y');
    expect(html).not.toContain('<script>x</script>');
    expect(html).toContain('Transcript');
    expect(html).not.toContain('Summary</h2>');
    expect(html).not.toMatch(/src="https?:/);
    expect(html).toContain('noindex');
  });
});
