import React, { PropsWithChildren, useCallback } from 'react';
import { Link, Route, RouteComponentProps, Switch, useRouteMatch } from 'react-router-dom';
import { ErrorBoundary } from 'react-error-boundary';
import classNames from 'classnames';
import { NotificationPrefs } from './preferences/NotificationPrefs';
import { SystemUpdatePrefs } from './preferences/SystemUpdatePrefs';
import notificationsSVG from '../assets/notifications.svg';
import systemUpdatesSVG from '../assets/system-updates.svg';
import { InterfacePrefs } from './preferences/InterfacePrefs';
import { useCharges } from '../state/docket';
import { AppPrefs } from './preferences/AppPrefs';
import { DocketImage } from '../components/DocketImage';
import { ErrorAlert } from '../components/ErrorAlert';

interface SystemPreferencesSectionProps {
  url: string;
  active: boolean;
}

function SystemPreferencesSection({
  url,
  active,
  children
}: PropsWithChildren<SystemPreferencesSectionProps>) {
  return (
    <li>
      <Link
        to={url}
        className={classNames(
          'flex items-center px-2 py-2 hover:text-black hover:bg-gray-50 rounded-xl',
          active && 'text-black bg-gray-50'
        )}
      >
        {children}
      </Link>
    </li>
  );
}

export const SystemPreferences = (props: RouteComponentProps<{ submenu: string }>) => {
  const { match, history } = props;
  const subMatch = useRouteMatch<{ submenu: string; desk?: string }>(
    `${match.url}/:submenu/:desk?`
  );
  const charges = useCharges();

  const matchSub = useCallback(
    (target: string, desk?: string) => {
      if (!subMatch && target === 'notifications') {
        return true;
      }

      if (desk && subMatch?.params.desk !== desk) {
        return false;
      }

      return subMatch?.params.submenu === target;
    },
    [match, subMatch]
  );

  const subUrl = useCallback((submenu: string) => `${match.url}/${submenu}`, [match]);

  return (
    <ErrorBoundary
      FallbackComponent={ErrorAlert}
      onReset={() => history.push('/leap/system-preferences')}
    >
      <div className="flex h-full overflow-y-auto">
        <aside className="flex-none self-start min-w-60 py-8 font-semibold border-r-2 border-gray-50">
          <nav className="px-6">
            <ul className="space-y-1">
              <SystemPreferencesSection
                url={subUrl('notifications')}
                active={matchSub('notifications')}
              >
                <img className="w-8 h-8 mr-3" src={notificationsSVG} alt="" />
                Notifications
              </SystemPreferencesSection>
              <SystemPreferencesSection
                url={subUrl('system-updates')}
                active={matchSub('system-updates')}
              >
                <img className="w-8 h-8 mr-3" src={systemUpdatesSVG} alt="" />
                System Updates
              </SystemPreferencesSection>
              <SystemPreferencesSection url={subUrl('interface')} active={matchSub('interface')}>
                <img className="w-8 h-8 mr-3" src={systemUpdatesSVG} alt="" />
                Interface Settings
              </SystemPreferencesSection>
            </ul>
          </nav>
          <hr className="my-4 border-t-2 border-gray-50" />
          <nav className="px-6">
            <ul className="space-y-1">
              {Object.values(charges).map((charge) => (
                <SystemPreferencesSection
                  key={charge.desk}
                  url={subUrl(`apps/${charge.desk}`)}
                  active={matchSub('apps', charge.desk)}
                >
                  <DocketImage size="small" className="mr-3" {...charge} />
                  {charge.title}
                </SystemPreferencesSection>
              ))}
            </ul>
          </nav>
        </aside>
        <section className="flex-1 min-h-[600px] p-8 text-black">
          <Switch>
            <Route path={`${match.url}/apps/:desk`} component={AppPrefs} />
            <Route path={`${match.url}/system-updates`} component={SystemUpdatePrefs} />
            <Route path={`${match.url}/interface`} component={InterfacePrefs} />
            <Route path={[`${match.url}/notifications`, match.url]} component={NotificationPrefs} />
          </Switch>
        </section>
      </div>
    </ErrorBoundary>
  );
};
