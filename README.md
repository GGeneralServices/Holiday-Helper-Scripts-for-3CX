# Holiday Helper for 3CX & Closure Helper for 3CX

Two menu-driven PowerShell scripts that manage department holidays on a 3CX V20 phone system through the 3CX Configuration API. No 3CX admin console experience is needed to use them.

| Script | File | Intended for |
|---|---|---|
| **Closure Helper for 3CX** | `CH-for-3CX.ps1` | Non-technical administrative staff |
| **Holiday Helper for 3CX** | `HH-for-3CX.ps1` | 3CX administrators |

---

## Closure Helper for 3CX

Closure Helper for 3CX lets administrative staff add a closure alert, such as for a snow day, to one or more departments in under a minute.

**What it does**

- **Add a Weather Closure:** choose the departments (or Select All), enter the date, and the script creates an all-day, one-time closure in each department. The closure plays your closure greeting.
- **View or Remove Weather Closures:** lists the departments that have an upcoming closure, so you can remove one or more closures across those departments at once.

**How it works**

- A closure is created as a 3CX department holiday named `Weather Closure`.
- If a department has an old closure from a past date, it is replaced automatically.
- If a department already has a future closure, the new one is named with its date, for example `Weather Closure - 01-15-2027`.
- Every change is read back from 3CX to confirm it was saved, and a summary is shown at the end.

## Holiday Helper for 3CX

Holiday Helper for 3CX lets 3CX administrators add holidays and events to many departments at the same time, instead of one department at a time in the admin console. It includes everything in Closure Helper for 3CX, plus:

- **Add a Holiday:** pick holidays from your holiday list, the departments, and one or more years. Dates are calculated automatically, including holidays like "4th Thursday of November".
- **Weekend holidays:** a holiday that falls on a weekend can be moved to the Friday before or the Monday after and labeled, for example `Christmas Day (Observed) 2027`. This behavior is configurable.
- **Add a Special Event:** a one-time event on a specific date, either all day or with start and end times.
- **Manage Holiday List:** add, edit, or remove the holidays offered by Add a Holiday, using guided prompts.
- **Duplicates and past dates:** holidays that already exist in a department, and dates that have already passed, are skipped automatically.

---

## Requirements

**3CX**

- **Version:** 3CX Version 20, which introduced the Configuration API (XAPI). Tested with version 20.0.9.
- **License:** 3CX states that the Configuration API requires an 8SC or higher Enterprise/AI license. Check 3CX's current licensing, as editions and requirements can change.
- **API client:** an API client set up in the 3CX admin console (see [Setup](#setup)).
- **Network access:** if Console Restrictions are on, each location that runs the scripts must be a permitted IP address (see [Setup](#setup)).

**Windows**

- Windows PowerShell 5.1 or PowerShell 7.
- The `Az.Accounts` and `Az.KeyVault` PowerShell modules.
- Network access to your 3CX server and to Azure.

**Azure**

- An Azure Key Vault that holds the 3CX API client ID and API key.
- Users who run the scripts need read access to those two secrets.

---

## Setup

### 1. Create a 3CX API client

1. In the 3CX admin console, go to **Integrations > API** and add a new client.
2. Enter a Client ID, and enable **3CX Configuration API Access**.
3. Set the **Department** to `DEFAULT` and the **Role** to **System Owner** or **System Admin**. Selecting "System Wide" locks the role to User, which can't manage holidays.
4. Save, then copy the API key. 3CX shows it only once.

### 2. Check Console Restrictions

If **Console Restrictions** are turned on in 3CX (**Advanced > Console Restrictions**, set to allow access from specific IP addresses), the Configuration API follows the same rules as the Admin Console. A computer that can't open the Admin Console from its location can't use these scripts either.

- **Add permitted IP addresses:** add the public IP address of each location where the scripts will run as a permitted IP address.
- **Local networks:** private and link-local addresses are always allowed. Computers on the same local network as the 3CX server usually work without changes.
- **Remote users:** people working from home or another site need a fixed public IP address that has been added, or a VPN connection to an allowed network.

### 3. Store the credentials in Azure Key Vault

1. Create a Key Vault that uses the **Azure role-based access control** permission model.
2. Add two secrets: one containing the 3CX Client ID, and one containing the API key.
3. On each secret, assign the **Key Vault Secrets User** role to the people or group who will run the scripts.

### 4. Install the PowerShell modules

```powershell
Install-Module Az.Accounts, Az.KeyVault -Scope CurrentUser
```

For managed computers, these modules can also be deployed to all users with Intune.

### 5. Create the settings file

1. Put both scripts in the same folder.
2. Run either script. On the first run, it creates `Helper-for-3CX-Settings.json` in that folder and then stops.
3. Open the file in a text editor and fill in your settings. Instructions are at the top of the file, and each setting has a short note above it.
4. Run the script again.

When the script starts, it signs you in to Azure (if needed), connects to 3CX, and opens the main menu. See [How credentials are handled](#how-credentials-are-handled) for details.

---

## Usage

```powershell
& ".\CH-for-3CX.ps1"          # Closure Helper for 3CX
& ".\HH-for-3CX.ps1"          # Holiday Helper for 3CX
& ".\HH-for-3CX.ps1" -Test    # Read from 3CX, but make no changes
```

- **Navigation:** choose options by number. Most screens also offer **B** (Back) and **M** (Main Menu).
- **`-Test`:** shows exactly what would be created or removed without changing anything in 3CX.

---

## Settings

All settings are stored in `Helper-for-3CX-Settings.json`, which both scripts share. The file is checked every time a script starts, and any missing or invalid settings are listed with instructions.

| Section | Contains |
|---|---|
| `PhoneSystem` | Your 3CX web address |
| `KeyVault` | Vault name, secret names, and an optional tenant ID |
| `ExcludedDepartments` | Departments to hide from department lists |
| `WeatherClosure` | Closure holiday name and greeting file name |
| `HolidaysAndEvents` | Holiday greeting, holiday list, and weekend observance rules (Holiday Helper for 3CX only) |
| `Testing` | Mock data and debug logging |

---

## Troubleshooting

- **Try a safe run first:** run with `-Test` to preview changes.
- **Debug logging:** set `Testing.DebugMode` to `"on"` to log every API call to `<script name>-Debug.log`. Secrets and access tokens are never logged.
- **Mock data:** set `Testing.UseMockData` to `true` to try the menus with sample data and no connection to 3CX.
- **Azure sign-in prompt during a session:** this is expected when the saved Azure sign-in has expired. The script needs it to renew its 3CX access token (see [How credentials are handled](#how-credentials-are-handled)).
- **403 Forbidden errors:** check the API client's role and department (see Setup step 1). Then check that the computer's public IP address is a permitted IP address in Console Restrictions (see Setup step 2).

---

## Security

### How credentials are handled

The 3CX API client ID and API key are stored only in Azure Key Vault. The scripts keep them in memory for as short a time as possible:

1. **Connect:** the script reads the client ID and API key from Key Vault and uses them to request a 3CX access token.
2. **Clear:** right after the token request, whether it succeeded or not, the credentials are cleared from memory. Only the access token is kept.
3. **Renew:** 3CX tokens expire after about an hour. Before each API call, the script checks the token's expiry time. If it is within a minute of expiring, the script repeats steps 1 and 2 to get a new token. If 3CX rejects a token early (401 Unauthorized), the script gets a new token and retries the request once.

The credentials and access tokens are never written to disk, the settings file, the screen, or the debug log.

Because renewal reads Key Vault again, it relies on the user's saved Azure sign-in. This is normally silent, but if the sign-in has expired or your organization requires multi-factor re-authentication, an Azure sign-in prompt may appear during a session.

### Other recommendations

- **Least privilege:** use the lowest 3CX role that works for the API client, and rotate the API key periodically.
- **Keep local files private.** `Helper-for-3CX-Settings.json` and the debug logs contain details about your phone system. Keep them out of source control (they are listed in `.gitignore`).

---

## Disclaimer

These scripts are not affiliated with or supported by 3CX. They make changes to your phone system, so test with `-Test` first and keep current 3CX backups.

## License

This project is licensed under the [MIT License](LICENSE). You're free to use, copy, modify, and share these scripts, provided the copyright and license notice are included. The scripts are provided "as is", without warranty of any kind.
