import { useEffect, useState } from "react";
import { getMe, logout, type Me } from "./api";
import Login from "./Login";
import Dashboard from "./Dashboard";

export default function App() {
  const [me, setMe] = useState<Me | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);

  const refresh = () =>
    getMe()
      .then((m) => {
        setMe(m);
        setError(null);
      })
      .catch((e: Error) => setError(e.message));

  useEffect(() => {
    refresh();
  }, []);

  if (error) {
    return (
      <main className="center-screen">
        <p className="notice">{error}</p>
        <button className="button" onClick={refresh}>Try again</button>
      </main>
    );
  }
  if (me === undefined) return <main className="center-screen" aria-busy="true" />;
  if (me === null) return <Login onSignedIn={refresh} />;
  return (
    <Dashboard
      me={me}
      onSignOut={async () => {
        await logout();
        setMe(null);
      }}
    />
  );
}
