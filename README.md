# jkapsalis.github.io

Personal site of Ioannis Kapsalis: home, about, and step-by-step infrastructure lab guides.

Live at <https://jkapsalis.github.io/>

## Structure

```
index.html                  Home
about/                      About me
projects/                   Project list
projects/saltstack/         SaltStack master & minions
projects/elk-stack/         ELK Stack + Filebeat on Docker
projects/vault-pki/         Vault PKI Interface Manager (+ the script)
projects/pacemaker/         Pacemaker HA web cluster
projects/tsql/              T-SQL attribute updates
assets/                     Shared CSS
```

Plain HTML and CSS, no build step. Preview locally:

```bash
python3 -m http.server 8000
```
