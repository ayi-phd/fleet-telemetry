// Battery charge as ten cells, filled in proportion to state of charge.
export default function Battery({ soc, charging }: { soc: number; charging: boolean }) {
  const filled = Math.round(soc / 10);
  const level = soc < 15 ? "low" : soc < 35 ? "mid" : "ok";
  return (
    <span className={`battery battery-${level}${charging ? " battery-charging" : ""}`} aria-label={`Battery ${Math.round(soc)} percent`}>
      <span className="battery-cells" aria-hidden="true">
        {Array.from({ length: 10 }, (_, i) => (
          <span key={i} className={i < filled ? "cell cell-on" : "cell"} />
        ))}
      </span>
      <span className="battery-value">{Math.round(soc)}%</span>
    </span>
  );
}
