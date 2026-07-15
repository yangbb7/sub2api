package service

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type alertSilenceRepoStub struct {
	OpsRepository
	createInput       *OpsAlertSilence
	isPlatform        string
	isUserID          *int64
	isAlertSilenced   bool
	isAlertSilenceErr error
}

func (s *alertSilenceRepoStub) CreateAlertSilence(_ context.Context, input *OpsAlertSilence) (*OpsAlertSilence, error) {
	s.createInput = input
	return input, nil
}

func (s *alertSilenceRepoStub) IsAlertSilenced(_ context.Context, _ int64, platform string, _ *int64, userID *int64, _ *string, _ time.Time) (bool, error) {
	s.isPlatform = platform
	s.isUserID = userID
	return s.isAlertSilenced, s.isAlertSilenceErr
}

func TestOpsServiceCreateAlertSilence_AllowsRuleScopedSilence(t *testing.T) {
	repo := &alertSilenceRepoStub{}
	svc := &OpsService{opsRepo: repo}
	until := time.Now().UTC().Add(time.Hour)

	created, err := svc.CreateAlertSilence(context.Background(), &OpsAlertSilence{
		RuleID:   7,
		Platform: "   ",
		Until:    until,
	})

	require.NoError(t, err)
	require.NotNil(t, created)
	require.NotNil(t, repo.createInput)
	require.Empty(t, repo.createInput.Platform)
}

func TestOpsServiceIsAlertSilenced_ForwardsRuleScopedSilence(t *testing.T) {
	repo := &alertSilenceRepoStub{isAlertSilenced: true}
	svc := &OpsService{opsRepo: repo}

	userID := int64(2)
	silenced, err := svc.IsAlertSilenced(context.Background(), 7, "   ", nil, &userID, nil, time.Now().UTC())

	require.NoError(t, err)
	require.True(t, silenced)
	require.Empty(t, repo.isPlatform)
	require.NotNil(t, repo.isUserID)
	require.Equal(t, int64(2), *repo.isUserID)
}
